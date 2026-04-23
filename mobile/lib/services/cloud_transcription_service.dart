import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../config/constants.dart';
import '../utils/wav_encoder.dart';
import 'vad_service.dart';
import 'whisper_service.dart' show WhisperService;

/// Azure OpenAI Whisper cloud transcription service.
///
/// Accepts PCM Float32 audio, encodes to WAV, and sends to Azure OpenAI
/// Whisper API for transcription.
class CloudTranscriptionService {
  final FlutterSecureStorage _storage;
  final HttpClient Function() _httpClientFactory;

  static const String _invalidCredentialMessage =
      'Access denied due to invalid subscription key or wrong API endpoint';

  CloudTranscriptionService({
    FlutterSecureStorage? storage,
    HttpClient Function()? httpClientFactory,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _httpClientFactory = httpClientFactory ?? (() => HttpClient());

  /// Max chunk duration in samples (10 minutes at 16 kHz, before downsampling).
  static const int _maxChunkSamples = 10 * 60 * 16000; // 9,600,000 samples

  /// Overlap between chunks (10 seconds at 16 kHz, before downsampling).
  static const int _overlapSamples = 10 * 16000; // 160,000 samples

  /// Transcribe audio using Azure OpenAI Whisper API.
  ///
  /// [samples] — raw PCM Float32 samples at 16 kHz.
  /// Returns the transcribed text.
  ///
  /// For recordings longer than 10 minutes, automatically splits into
  /// overlapping chunks and deduplicates at boundaries.
  Future<String> transcribe(List<double> samples) async {
    // Tier A: VAD-gate before upload to suppress silence hallucinations.
    // On failure (model missing, VAD error, or <20% speech kept) we fall
    // back to the raw buffer so behaviour is never worse than before.
    final Float32List? gated = await VadService.extractSpeech(samples);
    final List<double> effective =
        gated != null ? List<double>.from(gated) : samples;
    if (gated != null) {
      WhisperService.debugLog(
          '[CloudTranscriptionService] Using VAD-gated audio '
          '(${effective.length} samples, down from ${samples.length})');
    } else {
      WhisperService.debugLog(
          '[CloudTranscriptionService] VAD unavailable/low-confidence — '
          'uploading raw ${samples.length} samples');
    }

    if (effective.length <= _maxChunkSamples) {
      // Short recording — single request
      return _transcribeChunk(effective);
    }

    // Long recording — chunked transcription
    final parts = <String>[];
    String previousTail = '';

    for (int start = 0;
        start < effective.length;
        start += _maxChunkSamples - _overlapSamples) {
      final int end = min(start + _maxChunkSamples, effective.length);
      final chunk = effective.sublist(start, end);

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

    final hasStoredEndpoint = !(storedEndpoint?.isEmpty ?? true);
    final hasStoredKey = !(storedKey?.isEmpty ?? true);
    final endpoint = hasStoredEndpoint
        ? storedEndpoint!
        : AppConstants.defaultAzureWhisperUrl;
    final apiKey =
        hasStoredKey ? storedKey! : AppConstants.defaultAzureWhisperKey;

    // Downsample 16kHz → 8kHz to halve upload size (speech quality preserved)
    final downsampled = WavEncoder.downsample2x(samples);
    final Uint8List wavBytes = WavEncoder.encode(downsampled, sampleRate: 8000);
    WhisperService.debugLog('Cloud upload: ${wavBytes.length} bytes '
        '(${samples.length} samples → ${downsampled.length} downsampled)');

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

    // Prompt field intentionally omitted — even a short prompt was observed
    // being regurgitated by Whisper during silent/low-signal regions.
    // Spelling of eponyms/drug names is corrected downstream by the LLM.

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

    final shouldRetryWithDefaults = hasStoredEndpoint || hasStoredKey;
    try {
      try {
        return await _postTranscriptionRequest(
          uri: uri,
          apiKey: apiKey,
          boundary: boundary,
          bodyBytes: bodyBytes,
        );
      } catch (e) {
        final message = e.toString();
        final usingDefaults = endpoint == AppConstants.defaultAzureWhisperUrl &&
            apiKey == AppConstants.defaultAzureWhisperKey;
        if (!shouldRetryWithDefaults ||
            usingDefaults ||
            !message.contains(_invalidCredentialMessage)) {
          rethrow;
        }

        WhisperService.debugLog(
            '[CloudTranscriptionService] Stored Whisper credentials rejected. '
            'Retrying with built-in defaults.');
        await _storage.delete(
            key: AppConstants.secureStorageKeyAzureWhisperUrl);
        await _storage.delete(
            key: AppConstants.secureStorageKeyAzureWhisperKey);

        return _postTranscriptionRequest(
          uri: Uri.parse(AppConstants.defaultAzureWhisperUrl),
          apiKey: AppConstants.defaultAzureWhisperKey,
          boundary: boundary,
          bodyBytes: bodyBytes,
        );
      }
    } finally {}
  }

  Future<String> _postTranscriptionRequest({
    required Uri uri,
    required String apiKey,
    required String boundary,
    required List<int> bodyBytes,
  }) async {
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
        final raw = (json['text'] as String? ?? '').trim();
        return WhisperService.removeHallucinations(raw);
      }

      throw Exception(
          'Azure Whisper API error: HTTP ${response.statusCode} — $responseBody');
    } finally {
      httpClient.close();
    }
  }
}
