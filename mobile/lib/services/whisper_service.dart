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
  static const int _windowInterval = 3 * _sampleRate; // 3 seconds

  /// Overlap samples re-included in each window to preserve boundary words.
  static const int _overlapSamples = 1 * _sampleRate; // 1 second

  /// Model directory name for sherpa_onnx whisper model files.
  static const String _modelDirName = 'sherpa-onnx-whisper-small';

  /// Human-readable model name (for UI display).
  static const String modelDisplayName = 'Whisper Small';

  /// Model variant/quantization info.
  static const String modelVariant = 'INT8 (sherpa-onnx)';

  /// Expected minimum file sizes in bytes for integrity verification.
  /// Encoder ~120MB, Decoder ~130MB, Tokens ~100KB.
  /// We use conservative minimums (50% of typical) to catch truncated files.
  static const Map<String, int> _expectedMinSizes = {
    'small-encoder.int8.onnx': 50 * 1024 * 1024, // at least 50 MB
    'small-decoder.int8.onnx': 50 * 1024 * 1024, // at least 50 MB
    'small-tokens.txt': 10 * 1024, // at least 10 KB
  };

  /// RMS amplitude threshold below which audio is considered silence.
  /// Buffers quieter than this are skipped to prevent Whisper from
  /// hallucinating short interjections on ambient noise.
  static const double _silenceThreshold = 0.05;

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

  /// Check whether all model files exist and meet minimum size requirements.
  /// Returns true if model is ready to use, false if download is needed.
  static Future<bool> isModelDownloaded() async {
    if (kIsWeb) return true;
    final Directory docsDir = await getApplicationDocumentsDirectory();
    final String modelDir = '${docsDir.path}/$_modelDirName';
    for (final entry in _expectedMinSizes.entries) {
      final file = File('$modelDir/${entry.key}');
      if (!file.existsSync()) {
        debugLog('[WhisperService] File missing: ${entry.key}');
        return false;
      }
      final size = file.lengthSync();
      if (size < entry.value) {
        debugLog('[WhisperService] File too small: ${entry.key} '
            '($size bytes, expected >= ${entry.value})');
        return false;
      }
    }
    return true;
  }

  /// Delete all model files (corrupted, partial, or outdated).
  static Future<void> deleteModelFiles() async {
    if (kIsWeb) return;
    final Directory docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/$_modelDirName');
    if (dir.existsSync()) {
      debugLog('[WhisperService] Deleting model directory: ${dir.path}');
      dir.deleteSync(recursive: true);
    }
  }

  /// Verify model files are valid and delete any that are corrupted/partial.
  /// Returns true if all files are intact, false if re-download is needed.
  Future<bool> _verifyAndCleanModel(String modelDir) async {
    bool allValid = true;
    for (final entry in _expectedMinSizes.entries) {
      final file = File('$modelDir/${entry.key}');
      if (!file.existsSync()) {
        debugLog('[WhisperService] Missing: ${entry.key}');
        allValid = false;
        continue;
      }
      final size = file.lengthSync();
      if (size < entry.value) {
        debugLog('[WhisperService] Corrupted/partial ${entry.key}: '
            '$size bytes < ${entry.value} min. Deleting.');
        file.deleteSync();
        allValid = false;
      }
    }
    return allValid;
  }

  /// Simple debug logger that works in both debug and release.
  static void debugLog(String message) {
    // ignore: avoid_print
    print(message);
  }

  /// Downloads the Whisper model files (if not present) and initialises
  /// the transcription engine.
  ///
  /// On web this sets a no-op transcriber — on-device Whisper is not supported.
  Future<void> loadModel() async {
    if (kIsWeb) {
      _transcriber = (_) async => '';
      return;
    }

    debugLog('[WhisperService] loadModel() starting...');
    try {
      sherpa.initBindings();
      debugLog('[WhisperService] initBindings() succeeded.');
    } catch (e) {
      debugLog('[WhisperService] initBindings() FAILED: $e');
      rethrow;
    }

    final Directory docsDir = await getApplicationDocumentsDirectory();
    final String modelDir = '${docsDir.path}/$_modelDirName';

    _encoderPath = '$modelDir/small-encoder.int8.onnx';
    _decoderPath = '$modelDir/small-decoder.int8.onnx';
    _tokensPath = '$modelDir/small-tokens.txt';

    // Verify existing files — delete corrupted/partial ones
    final bool intact = await _verifyAndCleanModel(modelDir);
    if (!intact) {
      debugLog('[WhisperService] Model files incomplete, downloading...');
      await _downloadModel(modelDir, onProgress: _onDownloadProgress);
      // Verify again after download
      final bool ok = await _verifyAndCleanModel(modelDir);
      if (!ok) {
        throw Exception(
            'Model download failed: files still invalid after download');
      }
    }

    debugLog('[WhisperService] Initializing recognizer...');
    // Validate model files by creating a test recognizer
    try {
      final testRecognizer = sherpa.OfflineRecognizer(
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
      testRecognizer.free();
      debugLog('[WhisperService] Model validation passed.');
    } catch (e) {
      debugLog(
          '[WhisperService] Model validation FAILED: $e — deleting files.');
      await deleteModelFiles();
      throw Exception(
          'Model files corrupted, deleted. Restart to re-download. Error: $e');
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
  /// Uses chunked processing to avoid OOM on long recordings.
  Future<String> transcribeFull() async {
    if (_audioBuffer.isEmpty) return '';
    debugLog('[WhisperService] transcribeFull: ${_audioBuffer.length} samples '
        '(${(_audioBuffer.length / _sampleRate).toStringAsFixed(1)}s)');

    // For short recordings (< 30s), transcribe in one shot
    const int maxSinglePass = 30 * _sampleRate;
    if (_audioBuffer.length <= maxSinglePass) {
      return _runTranscriber(_audioBuffer);
    }

    // For longer recordings, use the same sliding-window approach
    // but process all windows sequentially for the final pass.
    const int chunkSize = 15 * _sampleRate; // 15s chunks
    const int overlap = 3 * _sampleRate; // 3s overlap
    final List<String> parts = [];
    String prevTail = '';

    for (int start = 0;
        start < _audioBuffer.length;
        start += chunkSize - overlap) {
      final int end = min(start + chunkSize, _audioBuffer.length);
      final chunk = _audioBuffer.sublist(start, end);

      // Skip silent chunks
      if (_rms(chunk) < _silenceThreshold) continue;

      try {
        final String text = await _runTranscriber(chunk);
        if (text.isEmpty) continue;
        final String deduped = removeOverlap(prevTail, text);
        if (deduped.isNotEmpty) parts.add(deduped);
        prevTail = _lastWords(text, 20);
      } catch (e) {
        debugLog('[WhisperService] transcribeFull chunk error: $e');
        // Continue with next chunk
      }
    }

    final result = parts.join(' ');
    debugLog('[WhisperService] transcribeFull done: ${result.length} chars');
    return result;
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

  /// Callback for download progress updates. Set externally before loadModel().
  void Function(String fileName, double progress)? _onDownloadProgress;

  /// Set a callback to receive download progress updates.
  set onDownloadProgress(void Function(String fileName, double progress)? cb) {
    _onDownloadProgress = cb;
  }

  /// Download whisper small model files from HuggingFace.
  /// Downloads to a temp file first, then renames — so partial downloads
  /// never leave a "valid-looking" file on disk.
  static Future<void> _downloadModel(
    String modelDir, {
    void Function(String fileName, double progress)? onProgress,
  }) async {
    final dir = Directory(modelDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    const baseUrl =
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main';
    final files = {
      'small-encoder.int8.onnx': '$baseUrl/small-encoder.int8.onnx',
      'small-decoder.int8.onnx': '$baseUrl/small-decoder.int8.onnx',
      'small-tokens.txt': '$baseUrl/small-tokens.txt',
    };

    final httpClient = HttpClient();
    try {
      int fileIndex = 0;
      for (final entry in files.entries) {
        final filePath = '$modelDir/${entry.key}';
        final file = File(filePath);

        // Skip if already downloaded and valid size
        if (file.existsSync()) {
          final minSize = _expectedMinSizes[entry.key] ?? 0;
          if (file.lengthSync() >= minSize) {
            debugLog('[WhisperService] ${entry.key} already valid, skipping.');
            fileIndex++;
            continue;
          }
          // Corrupted — delete and re-download
          debugLog('[WhisperService] ${entry.key} too small, re-downloading.');
          file.deleteSync();
        }

        // Clean up any leftover temp file
        final tmpPath = '$filePath.tmp';
        final tmpFile = File(tmpPath);
        if (tmpFile.existsSync()) tmpFile.deleteSync();

        debugLog('[WhisperService] Downloading ${entry.key}...');
        final request = await httpClient.getUrl(Uri.parse(entry.value));
        final response = await request.close();

        if (response.statusCode >= 200 && response.statusCode < 400) {
          final contentLength = response.contentLength;
          final sink = tmpFile.openWrite();
          int received = 0;

          await for (final chunk in response) {
            sink.add(chunk);
            received += chunk.length;
            if (onProgress != null && contentLength > 0) {
              final fileProgress = received / contentLength;
              final overall = (fileIndex + fileProgress) / files.length;
              onProgress(entry.key, overall);
            }
          }
          await sink.close();

          // Verify downloaded size before renaming
          final downloadedSize = tmpFile.lengthSync();
          final minSize = _expectedMinSizes[entry.key] ?? 0;
          if (downloadedSize < minSize) {
            tmpFile.deleteSync();
            throw Exception(
              'Downloaded ${entry.key} too small: $downloadedSize bytes',
            );
          }

          // Atomic rename: only a complete file gets the final name
          tmpFile.renameSync(filePath);
          debugLog('[WhisperService] ${entry.key} downloaded OK '
              '($downloadedSize bytes).');
        } else {
          throw Exception(
            'Failed to download ${entry.key}: HTTP ${response.statusCode}',
          );
        }
        fileIndex++;
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
