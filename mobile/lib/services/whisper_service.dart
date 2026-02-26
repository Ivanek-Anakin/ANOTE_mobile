import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// A function that transcribes a list of float32 audio samples to text.
typedef AudioTranscriber = Future<String> Function(List<double> samples);

/// Manages on-device speech transcription with sliding-window buffering.
///
/// Uses sherpa_onnx (Whisper ONNX) on native platforms (Android/iOS/desktop).
/// On web, transcription is unavailable (returns empty string).
///
/// Usage:
/// 1. Call [loadModel] once to download and initialise the model.
/// 2. Feed incoming audio via [feedAudio]; [transcriptStream] emits live updates.
/// 3. On recording stop, call [transcribeFull] for a final high-quality pass.
/// 4. Call [reset] between sessions and [dispose] when done.
class WhisperService {
  static const int _sampleRate = 16000;

  /// Number of new samples required before a window transcription is triggered.
  static const int _windowInterval = 5 * _sampleRate; // 5 seconds

  /// Overlap samples re-included in each window to preserve boundary words.
  static const int _overlapSamples = 2 * _sampleRate; // 2 seconds

  /// Model directory name for sherpa_onnx whisper model files.
  static const String _modelDirName = 'sherpa-onnx-whisper-tiny';

  /// RMS amplitude threshold below which audio is considered silence.
  /// Buffers quieter than this are skipped to prevent Whisper from
  /// hallucinating short interjections on ambient noise.
  static const double _silenceThreshold = 0.01;

  final List<double> _audioBuffer = [];
  int _lastBoundary = 0;
  String _previousTailText = '';
  String _fullTranscript = '';
  bool _isTranscribing = false;

  /// Injectable transcribe function — set by [loadModel] or supplied in tests.
  AudioTranscriber? _transcriber;

  /// Paths to model files (set during loadModel).
  String _encoderPath = '';
  String _decoderPath = '';
  String _tokensPath = '';

  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();

  /// Stream of incremental transcript updates during recording.
  Stream<String> get transcriptStream => _transcriptController.stream;

  /// Whether the model is ready for transcription.
  bool get isModelLoaded => _transcriber != null;

  /// Production constructor — call [loadModel] before use.
  WhisperService();

  /// Test constructor — injects a custom [transcriber] function to avoid
  /// loading the real model in unit tests.
  WhisperService.withTranscriber(AudioTranscriber transcriber)
      : _transcriber = transcriber;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Downloads the Whisper model files (if not present) and initialises
  /// the transcription engine.
  ///
  /// On web this sets a no-op transcriber — on-device Whisper is not supported.
  Future<void> loadModel() async {
    if (kIsWeb) {
      _transcriber = (_) async => '';
      return;
    }

    sherpa.initBindings();

    final Directory docsDir = await getApplicationDocumentsDirectory();
    final String modelDir = '${docsDir.path}/$_modelDirName';

    _encoderPath = '$modelDir/tiny-encoder.int8.onnx';
    _decoderPath = '$modelDir/tiny-decoder.int8.onnx';
    _tokensPath = '$modelDir/tiny-tokens.txt';

    // Download model files if missing
    if (!File(_encoderPath).existsSync() ||
        !File(_decoderPath).existsSync() ||
        !File(_tokensPath).existsSync()) {
      await _downloadModel(modelDir);
    }

    _transcriber = (List<double> samples) async {
      final recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            whisper: sherpa.OfflineWhisperModelConfig(
              encoder: _encoderPath,
              decoder: _decoderPath,
              language: 'cs',
              task: 'transcribe',
              tailPaddings: 800,
            ),
            tokens: _tokensPath,
            numThreads: 2,
            debug: false,
            provider: 'cpu',
          ),
        ),
      );
      try {
        final stream = recognizer.createStream();
        stream.acceptWaveform(
          samples: Float32List.fromList(samples),
          sampleRate: _sampleRate,
        );
        recognizer.decode(stream);
        final result = recognizer.getResult(stream);
        stream.free();
        return result.text.trim();
      } finally {
        recognizer.free();
      }
    };
  }

  /// Accept new audio [samples] from the microphone stream.
  ///
  /// Triggers a sliding-window transcription when enough new audio has
  /// accumulated ([_windowInterval] samples since [_lastBoundary]).
  void feedAudio(List<double> samples) {
    _audioBuffer.addAll(samples);
    if (!_isTranscribing &&
        _audioBuffer.length - _lastBoundary >= _windowInterval) {
      _transcribeWindow();
    }
  }

  /// Transcribe the entire audio buffer in a single high-quality pass.
  ///
  /// Called on recording stop to produce the definitive transcript.
  Future<String> transcribeFull() async {
    if (_audioBuffer.isEmpty) return '';
    return _runTranscriber(_audioBuffer);
  }

  /// Clear all audio buffers and accumulated transcript state.
  void reset() {
    _audioBuffer.clear();
    _lastBoundary = 0;
    _previousTailText = '';
    _fullTranscript = '';
    _isTranscribing = false;
  }

  /// Release all resources.
  void dispose() {
    reset();
    if (!_transcriptController.isClosed) {
      _transcriptController.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers
  // ---------------------------------------------------------------------------

  /// Calculate root-mean-square amplitude of [samples].
  static double _rms(List<double> samples) {
    if (samples.isEmpty) return 0.0;
    double sumSq = 0.0;
    for (final s in samples) {
      sumSq += s * s;
    }
    return sqrt(sumSq / samples.length);
  }

  Future<void> _transcribeWindow() async {
    if (_isTranscribing) return;
    if (_audioBuffer.length - _lastBoundary < _windowInterval) return;
    _isTranscribing = true;

    try {
      final int overlapStart = max(0, _lastBoundary - _overlapSamples);
      // Snapshot the buffer end BEFORE the async call so we don't skip audio
      // that arrives while we're transcribing.
      final int windowEnd = _audioBuffer.length;
      final List<double> window =
          List<double>.from(_audioBuffer.sublist(overlapStart, windowEnd));

      // Skip transcription if the window is too quiet (silence / ambient noise).
      if (_rms(window) < _silenceThreshold) {
        _lastBoundary = windowEnd;
        return;
      }

      final String rawText = await _runTranscriber(window);
      if (rawText.isEmpty) {
        _lastBoundary = windowEnd;
        return;
      }

      final String deduped = removeOverlap(_previousTailText, rawText);
      if (deduped.isNotEmpty) {
        _fullTranscript =
            _fullTranscript.isEmpty ? deduped : '$_fullTranscript $deduped';
      }

      _previousTailText = _lastWords(rawText, 20);
      _lastBoundary = windowEnd;

      if (!_transcriptController.isClosed) {
        _transcriptController.add(_fullTranscript);
      }
    } catch (_) {
      // Don't propagate transcription errors — preserve recording continuity.
    } finally {
      _isTranscribing = false;
    }
  }

  Future<String> _runTranscriber(List<double> samples) async {
    if (_transcriber == null) {
      throw StateError('Whisper model not loaded — call loadModel() first.');
    }
    return _transcriber!(samples);
  }

  /// Download whisper tiny model files from HuggingFace.
  static Future<void> _downloadModel(String modelDir) async {
    final dir = Directory(modelDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    const baseUrl =
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-tiny/resolve/main';
    final files = {
      'tiny-encoder.int8.onnx': '$baseUrl/tiny-encoder.int8.onnx',
      'tiny-decoder.int8.onnx': '$baseUrl/tiny-decoder.int8.onnx',
      'tiny-tokens.txt': '$baseUrl/tiny-tokens.txt',
    };

    final httpClient = HttpClient();
    try {
      for (final entry in files.entries) {
        final filePath = '$modelDir/${entry.key}';
        if (File(filePath).existsSync()) continue;

        final request = await httpClient.getUrl(Uri.parse(entry.value));
        final response = await request.close();

        if (response.statusCode >= 200 && response.statusCode < 400) {
          final file = File(filePath);
          final sink = file.openWrite();
          await response.pipe(sink);
          await sink.close();
        } else {
          throw Exception(
            'Failed to download ${entry.key}: HTTP ${response.statusCode}',
          );
        }
      }
    } finally {
      httpClient.close();
    }
  }

  // ---------------------------------------------------------------------------
  // Static utilities (exposed for testing)
  // ---------------------------------------------------------------------------

  /// Remove words from the beginning of [newText] that already appear at
  /// the end of [previousTail], eliminating overlap caused by the sliding window.
  ///
  /// Matching uses normalised comparison (lowercase, diacritics stripped)
  /// but preserves the original casing/accents in the returned text.
  static String removeOverlap(String previousTail, String newText) {
    if (previousTail.isEmpty || newText.isEmpty) return newText;

    final List<String> tailWords = _normalizeText(previousTail)
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    final List<String> newWords =
        newText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final List<String> normalizedNew = newWords.map(_normalizeWord).toList();

    // Find longest suffix of tailWords that matches a prefix of normalizedNew
    final int maxLen = min(tailWords.length, normalizedNew.length);
    for (int len = maxLen; len > 0; len--) {
      final List<String> tailSuffix = tailWords.sublist(tailWords.length - len);
      final List<String> newPrefix = normalizedNew.sublist(0, len);
      if (_listsEqual(tailSuffix, newPrefix)) {
        return newWords.sublist(len).join(' ');
      }
    }
    return newText;
  }

  static String _normalizeText(String text) =>
      text.split(RegExp(r'\s+')).map(_normalizeWord).join(' ');

  static String _normalizeWord(String word) => word
      .toLowerCase()
      .replaceAll(RegExp('[áà]'), 'a')
      .replaceAll(RegExp('[éě]'), 'e')
      .replaceAll(RegExp('[íì]'), 'i')
      .replaceAll(RegExp('[óò]'), 'o')
      .replaceAll(RegExp('[úůù]'), 'u')
      .replaceAll('ý', 'y')
      .replaceAll('č', 'c')
      .replaceAll('š', 's')
      .replaceAll('ž', 'z')
      .replaceAll('ř', 'r')
      .replaceAll('ň', 'n')
      .replaceAll('ď', 'd')
      .replaceAll('ť', 't')
      .replaceAll(RegExp('[.,;:!?]'), '');

  static bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static String _lastWords(String text, int n) {
    final List<String> words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length <= n) return text;
    return words.sublist(words.length - n).join(' ');
  }
}
