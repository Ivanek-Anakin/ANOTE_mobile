import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/constants.dart';
import '../utils/wav_encoder.dart';
import 'whisper_service.dart' show WhisperService;

/// Azure OpenAI Whisper cloud transcription service.
///
/// Accepts PCM Float32 audio, encodes to WAV, and sends to Azure OpenAI
/// Whisper API for transcription.
class CloudTranscriptionService {
  final FlutterSecureStorage _storage;
  final HttpClient Function() _httpClientFactory;

  CloudTranscriptionService({
    FlutterSecureStorage? storage,
    HttpClient Function()? httpClientFactory,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _httpClientFactory = httpClientFactory ?? (() => HttpClient());

  /// Max chunk duration in samples (10 minutes at 16 kHz to stay under 25 MB).
  static const int _maxChunkSamples = 10 * 60 * 16000; // 9,600,000 samples

  /// Overlap between chunks (10 seconds at 16 kHz).
  static const int _overlapSamples = 10 * 16000; // 160,000 samples

  /// Transcribe audio using Azure OpenAI Whisper API.
  ///
  /// [samples] — raw PCM Float32 samples at 16 kHz.
  /// Returns the transcribed text.
  ///
  /// For recordings longer than 10 minutes, automatically splits into
  /// overlapping chunks and deduplicates at boundaries.
  Future<String> transcribe(List<double> samples) async {
    if (samples.length <= _maxChunkSamples) {
      // Short recording — single request
      return _transcribeChunk(samples);
    }

    // Long recording — chunked transcription
    final parts = <String>[];
    String previousTail = '';

    for (int start = 0;
        start < samples.length;
        start += _maxChunkSamples - _overlapSamples) {
      final int end = min(start + _maxChunkSamples, samples.length);
      final chunk = samples.sublist(start, end);

      final text = await _transcribeChunk(chunk);
      if (text.isEmpty) continue;

      final deduped = WhisperService.removeOverlap(previousTail, text);
      if (deduped.isNotEmpty) parts.add(deduped);
      previousTail = WhisperService.lastWords(text, 30);
    }

    return parts.join(' ');
  }

  /// Transcribe a single chunk via Azure OpenAI Whisper API.
  Future<String> _transcribeChunk(List<double> samples) async {
    final storedEndpoint =
        await _storage.read(key: AppConstants.secureStorageKeyAzureWhisperUrl);
    final storedKey =
        await _storage.read(key: AppConstants.secureStorageKeyAzureWhisperKey);

    final endpoint = (storedEndpoint?.isEmpty ?? true)
        ? AppConstants.defaultAzureWhisperUrl
        : storedEndpoint!;
    final apiKey = (storedKey?.isEmpty ?? true)
        ? AppConstants.defaultAzureWhisperKey
        : storedKey!;

    // Encode PCM to WAV
    final Uint8List wavBytes = WavEncoder.encode(samples, sampleRate: 16000);

    // Build multipart request
    final uri = Uri.parse(endpoint);
    final boundary =
        '----DartFormBoundary${DateTime.now().millisecondsSinceEpoch}';

    final bodyParts = <List<int>>[];

    // File field
    bodyParts.add(utf8.encode('--$boundary\r\n'));
    bodyParts.add(utf8.encode(
        'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n'));
    bodyParts.add(utf8.encode('Content-Type: audio/wav\r\n\r\n'));
    bodyParts.add(wavBytes);
    bodyParts.add(utf8.encode('\r\n'));

    // Language field
    bodyParts.add(utf8.encode('--$boundary\r\n'));
    bodyParts.add(utf8.encode(
        'Content-Disposition: form-data; name="language"\r\n\r\ncs\r\n'));

    // Prompt field — guides Whisper toward Czech medical terminology
    bodyParts.add(utf8.encode('--$boundary\r\n'));
    bodyParts.add(utf8.encode(
        'Content-Disposition: form-data; name="prompt"\r\n\r\n'
        'Lékařská prohlídka, anamnéza pacienta, nynější onemocnění. '
        'Homansovo znamení, Murphyho znamení, Lasègueovo znamení. '
        'Hluboká žilní trombóza, plicní embolie, infarkt myokardu, fibrilace síní. '
        'CT angiografie, RTG plic, EKG, echokardiografie, gastroskopie, kolonoskopie. '
        'Chrůpky, krepitace, vrzoty, dýchání sklípkové, poklep plný jasný. '
        'Krevní tlak, tepová frekvence, saturace kyslíkem, dechová frekvence. '
        'Metformin, Prestarium, bisoprolol, atorvastatin, warfarin, heparin, furosemid. '
        'Cirhóza, pneumonie, cholecystitida, appendicitida, pankreatitida. '
        'Alergická anamnéza, farmakologická anamnéza, rodinná anamnéza. '
        'Hypertenze, diabetes mellitus, hypercholesterolémie. '
        'Objektivní nález, subjektivní potíže, pracovní diagnóza.\r\n'));

    // Response format field
    bodyParts.add(utf8.encode('--$boundary\r\n'));
    bodyParts.add(utf8.encode(
        'Content-Disposition: form-data; name="response_format"\r\n\r\njson\r\n'));

    // Closing boundary
    bodyParts.add(utf8.encode('--$boundary--\r\n'));

    final bodyBytes = <int>[];
    for (final part in bodyParts) {
      bodyBytes.addAll(part);
    }

    final httpClient = _httpClientFactory();
    try {
      final request = await httpClient.postUrl(uri);
      request.headers.set('api-key', apiKey);
      request.headers
          .set('Content-Type', 'multipart/form-data; boundary=$boundary');
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final json = jsonDecode(responseBody) as Map<String, dynamic>;
        return (json['text'] as String? ?? '').trim();
      } else {
        throw Exception(
            'Azure Whisper API error: HTTP ${response.statusCode} — $responseBody');
      }
    } finally {
      httpClient.close();
    }
  }
}
