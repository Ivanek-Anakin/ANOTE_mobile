import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:whisper_flutter_plus/whisper_flutter_plus.dart';

import '../utils/wav_encoder.dart';

/// A function that transcribes a list of float32 audio samples to text.
typedef AudioTranscriber = Future<String> Function(List<double> samples);

/// Manages on-device Whisper.cpp transcription with sliding-window buffering.
///
/// Usage:
/// 1. Call [loadModel] once to copy and initialise the Whisper model.
/// 2. Feed incoming audio via [feedAudio]; [transcriptStream] emits live updates.
/// 3. On recording stop, call [transcribeFull] for a final high-quality pass.
/// 4. Call [reset] between sessions and [dispose] when done.
class WhisperService {
  static const int _sampleRate = 16000;

  /// Number of new samples required before a window transcription is triggered.
  static const int _windowInterval = 5 * _sampleRate; // 5 seconds

  /// Overlap samples re-included in each window to preserve boundary words.
  static const int _overlapSamples = 2 * _sampleRate; // 2 seconds

  final List<double> _audioBuffer = [];
  int _lastBoundary = 0;
  String _previousTailText = '';
  String _fullTranscript = '';
  bool _isTranscribing = false;

  /// Injectable transcribe function — set by [loadModel] or supplied in tests.
  AudioTranscriber? _transcriber;

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

  /// Copies the Whisper model from Flutter assets to the documents directory
  /// (if not already present) and initialises the runtime.
  Future<void> loadModel() async {
    final Directory docsDir = await getApplicationDocumentsDirectory();
    final String modelPath = '${docsDir.path}/ggml-small.bin';
    final File modelFile = File(modelPath);

    if (!modelFile.existsSync()) {
      final ByteData data =
          await rootBundle.load('assets/models/ggml-small.bin');
      await modelFile.writeAsBytes(data.buffer.asUint8List());
    }

    final Whisper whisper =
        Whisper(model: WhisperModel.small, modelDir: docsDir.path);

    _transcriber = (List<double> samples) async {
      final Uint8List wavBytes = WavEncoder.encode(samples);
      final Directory tempDir = await getTemporaryDirectory();
      final String wavPath =
          '${tempDir.path}/whisper_${DateTime.now().millisecondsSinceEpoch}.wav';
      final File wavFile = File(wavPath);
      await wavFile.writeAsBytes(wavBytes);
      try {
        final WhisperTranscribeResponse response = await whisper.transcribe(
          transcribeRequest: TranscribeRequest(
            audio: wavPath,
            language: 'cs',
            isTranslate: false,
            threads: 4,
          ),
        );
        return response.text.trim();
      } finally {
        try {
          wavFile.deleteSync();
        } catch (_) {}
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

      final String rawText = await _runTranscriber(window);
      if (rawText.isEmpty) {
        _lastBoundary = windowEnd;
        return;
      }

      final String deduped = removeOverlap(_previousTailText, rawText);
      if (deduped.isNotEmpty) {
        _fullTranscript = _fullTranscript.isEmpty
            ? deduped
            : '$_fullTranscript $deduped';
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
      final List<String> tailSuffix =
          tailWords.sublist(tailWords.length - len);
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
