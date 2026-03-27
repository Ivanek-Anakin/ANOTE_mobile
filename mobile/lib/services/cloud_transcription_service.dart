import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/constants.dart';
import '../utils/wav_encoder.dart';

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

  /// Transcribe audio using Azure OpenAI Whisper API.
  ///
  /// [samples] — raw PCM Float32 samples at 16 kHz.
  /// Returns the transcribed text.
  Future<String> transcribe(List<double> samples) async {
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
    bodyParts
        .add(utf8.encode('Content-Disposition: form-data; name="prompt"\r\n\r\n'
            'Lékařská prohlídka, anamnéza pacienta. '
            'Diagnóza, terapie, medikace, vyšetření. '
            'Krevní tlak, saturace, EKG, glykémie, BMI. '
            'Pacient, pacientka, doktor, ordinace.\r\n'));

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
