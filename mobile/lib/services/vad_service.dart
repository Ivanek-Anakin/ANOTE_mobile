import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'whisper_service.dart' show WhisperService;

/// Standalone Silero VAD service for the cloud transcription path.
///
/// Runs independently of [WhisperService] so it works for cloud-only users
/// who never download the on-device Whisper models. The VAD model
/// (`silero_vad.onnx`, ~300 KB) is downloaded on first use and stored in
/// `<app-docs>/vad/silero_vad.onnx`.
///
/// The main entry point is [extractSpeech], which takes raw Float32 PCM
/// samples, detects speech segments via Silero VAD on a background isolate,
/// and returns a concatenated Float32List containing only speech (with short
/// silence padding between segments). Falls back gracefully: callers should
/// handle `null` return and upload raw audio instead.
class VadService {
  VadService._();

  static const String _vadModelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

  /// Minimum expected size of silero_vad.onnx (~1.8 MB actual, 300 KB
  /// guard-threshold matches the check in [WhisperService]).
  static const int _minModelSize = 300 * 1024;

  /// Ratio of samples that must survive VAD for the result to be trusted.
  /// If VAD keeps < this, the caller should treat it as a false-negative and
  /// upload the raw buffer instead.
  static const double minSpeechRatio = 0.20;

  /// Silence padding inserted between concatenated speech segments (seconds).
  static const double _interSegmentPaddingSec = 0.10;

  /// Guard padding prepended/appended to each segment (seconds) to avoid
  /// clipping word boundaries.
  static const double _guardPaddingSec = 0.15;

  static String? _cachedModelPath;
  static Future<String?>? _ensureModelFuture;

  /// Ensures `silero_vad.onnx` is present on disk. Downloads it once if
  /// missing. Returns the absolute path, or `null` if the model is unavailable
  /// (e.g. offline on first run).
  static Future<String?> ensureModel() {
    return _ensureModelFuture ??= _ensureModelInternal();
  }

  static Future<String?> _ensureModelInternal() async {
    try {
      if (_cachedModelPath != null) return _cachedModelPath;
      final Directory docsDir = await getApplicationDocumentsDirectory();
      final Directory vadDir = Directory('${docsDir.path}/vad');
      if (!vadDir.existsSync()) vadDir.createSync(recursive: true);
      final File modelFile = File('${vadDir.path}/silero_vad.onnx');

      if (modelFile.existsSync() &&
          await modelFile.length() >= _minModelSize) {
        _cachedModelPath = modelFile.path;
        return _cachedModelPath;
      }

      // Try to reuse the VAD model already downloaded for on-device Whisper
      // to avoid a duplicate download.
      final Directory whisperDir =
          Directory('${docsDir.path}/whisper_small_int8_with_vad');
      final File whisperVad = File('${whisperDir.path}/silero_vad.onnx');
      if (whisperVad.existsSync() &&
          await whisperVad.length() >= _minModelSize) {
        try {
          await whisperVad.copy(modelFile.path);
          _cachedModelPath = modelFile.path;
          return _cachedModelPath;
        } catch (_) {
          // fall through to network download
        }
      }

      WhisperService.debugLog('[VadService] Downloading silero_vad.onnx...');
      final HttpClient http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 15)
        ..idleTimeout = const Duration(seconds: 15);
      try {
        final HttpClientRequest req =
            await http.getUrl(Uri.parse(_vadModelUrl));
        final HttpClientResponse res = await req.close();
        if (res.statusCode != 200) {
          WhisperService.debugLog(
              '[VadService] Download failed: HTTP ${res.statusCode}');
          return null;
        }
        final File tmp = File('${modelFile.path}.part');
        final IOSink sink = tmp.openWrite();
        await res.pipe(sink);
        if (await tmp.length() < _minModelSize) {
          WhisperService.debugLog(
              '[VadService] Downloaded file too small, discarding.');
          await tmp.delete();
          return null;
        }
        await tmp.rename(modelFile.path);
        _cachedModelPath = modelFile.path;
        WhisperService.debugLog(
            '[VadService] VAD model ready at ${modelFile.path}');
        return _cachedModelPath;
      } finally {
        http.close(force: true);
      }
    } catch (e) {
      WhisperService.debugLog('[VadService] ensureModel error: $e');
      // Reset so a later call can retry
      _ensureModelFuture = null;
      return null;
    }
  }

  /// Run Silero VAD on [samples] (Float32 PCM @ 16 kHz) and return a
  /// concatenated buffer containing only speech segments, separated by short
  /// silence padding. Returns `null` if VAD is unavailable or if it kept
  /// too little audio to be trusted — callers should fall back to the raw
  /// buffer in both cases.
  static Future<Float32List?> extractSpeech(
    List<double> samples, {
    int sampleRate = 16000,
  }) async {
    if (samples.isEmpty) return null;
    final String? modelPath = await ensureModel();
    if (modelPath == null) return null;

    try {
      final Float32List? result = await Isolate.run(() {
        return _runVad(
          Float32List.fromList(samples),
          modelPath,
          sampleRate,
        );
      });

      if (result == null || result.isEmpty) return null;
      final double ratio = result.length / samples.length;
      WhisperService.debugLog(
          '[VadService] VAD kept ${result.length}/${samples.length} '
          'samples (${(ratio * 100).toStringAsFixed(1)}%)');
      if (ratio < minSpeechRatio) return null;
      return result;
    } catch (e) {
      WhisperService.debugLog('[VadService] extractSpeech error: $e');
      return null;
    }
  }

  /// Runs inside [Isolate.run] — pure function, no Flutter bindings.
  static Float32List? _runVad(
    Float32List samples,
    String modelPath,
    int sampleRate,
  ) {
    final int guardPad = (_guardPaddingSec * sampleRate).round();
    final int interPad = (_interSegmentPaddingSec * sampleRate).round();

    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: modelPath,
          threshold: 0.35,
          minSilenceDuration: 0.5,
          minSpeechDuration: 0.25,
          maxSpeechDuration: 30.0,
          windowSize: 512,
        ),
        sampleRate: sampleRate,
        numThreads: 1,
        provider: 'cpu',
        debug: false,
      ),
      bufferSizeInSeconds: 120.0,
    );

    try {
      const int windowSize = 512;
      final segments = <(int, int)>[]; // (start, end) in sample indices

      int cursor = 0;
      for (int i = 0; i < samples.length; i += windowSize) {
        final int end = min(i + windowSize, samples.length);
        Float32List chunk;
        if (end - i == windowSize) {
          chunk = Float32List.sublistView(samples, i, end);
        } else {
          chunk = Float32List(windowSize);
          for (int j = 0; j < end - i; j++) {
            chunk[j] = samples[i + j];
          }
        }
        vad.acceptWaveform(chunk);

        while (!vad.isEmpty()) {
          final seg = vad.front();
          vad.pop();
          if (seg.samples.isEmpty) continue;
          // Sherpa segments expose .start (sample index at 16kHz) and
          // .samples. We reconstruct absolute bounds from .start.
          final int segStart = seg.start;
          final int segEnd = segStart + seg.samples.length;
          segments.add((segStart, segEnd));
          cursor = segEnd;
        }
      }

      vad.flush();
      while (!vad.isEmpty()) {
        final seg = vad.front();
        vad.pop();
        if (seg.samples.isEmpty) continue;
        final int segStart = seg.start;
        final int segEnd = segStart + seg.samples.length;
        segments.add((segStart, segEnd));
        cursor = segEnd;
      }
      // silence unused-warning
      if (cursor < 0) return null;

      if (segments.isEmpty) return null;

      // Apply guard padding + concatenate with inter-segment silence
      final List<Float32List> pieces = [];
      int totalLen = 0;
      for (int i = 0; i < segments.length; i++) {
        final (segStart, segEnd) = segments[i];
        final int padStart = max(0, segStart - guardPad);
        final int padEnd = min(samples.length, segEnd + guardPad);
        final Float32List slice =
            Float32List.sublistView(samples, padStart, padEnd);
        pieces.add(slice);
        totalLen += slice.length;
        if (i < segments.length - 1) totalLen += interPad;
      }

      final Float32List out = Float32List(totalLen);
      int offset = 0;
      for (int i = 0; i < pieces.length; i++) {
        final Float32List p = pieces[i];
        out.setRange(offset, offset + p.length, p);
        offset += p.length;
        if (i < pieces.length - 1) offset += interPad; // silence (zeros)
      }
      return out;
    } finally {
      vad.free();
    }
  }
}
