import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'whisper_isolate_worker.dart';

/// Configuration for a Whisper model variant.
class WhisperModelConfig {
  final String dirName;
  final String encoderFile;
  final String decoderFile;
  final String tokensFile;
  final String baseUrl;
  final String displayName;
  final String variant;
  final int sizeMB;
  final Map<String, int> expectedMinSizes;

  const WhisperModelConfig({
    required this.dirName,
    required this.encoderFile,
    required this.decoderFile,
    required this.tokensFile,
    required this.baseUrl,
    required this.displayName,
    required this.variant,
    required this.sizeMB,
    required this.expectedMinSizes,
  });
}

// ---------------------------------------------------------------------------
// Phase 2: Top-level function for one-shot isolate transcription.
// Kept as a standalone utility; Phase 3's persistent worker handles
// transcribeFull internally via the long-lived worker isolate.
// ---------------------------------------------------------------------------

/// Runs the full transcription pipeline in a **one-shot** isolate.
///
/// Can be used with [compute] as a fallback when the persistent worker is
/// not available. Accepts model file paths and raw audio data.
///
/// Keys in [params]:
/// - `audio` ([Float32List]) — raw PCM samples at 16 kHz
/// - `encoderPath`, `decoderPath`, `tokensPath`, `vadModelPath` ([String])
Future<String> transcribeFullInIsolate(Map<String, dynamic> params) async {
  final Float32List audio = params['audio'] as Float32List;
  final String encoderPath = params['encoderPath'] as String;
  final String decoderPath = params['decoderPath'] as String;
  final String tokensPath = params['tokensPath'] as String;
  final String vadModelPath = params['vadModelPath'] as String;
  final String hotwordsFilePath = (params['hotwordsFilePath'] as String?) ?? '';

  const int sampleRate = 16000;

  // Initialize sherpa bindings in this isolate (FFI state is per-isolate)
  sherpa.initBindings();

  // Extract speech segments using fresh VAD
  final segments = _extractSpeechSegmentsStandalone(
    audio.toList(),
    vadModelPath,
    sampleRate,
  );
  if (segments.isEmpty) return '';

  final allSpeech = <double>[];
  for (final seg in segments) {
    allSpeech.addAll(seg.toList());
  }

  // Resolve hotwords path — only pass if file exists
  final String resolvedHotwords =
      hotwordsFilePath.isNotEmpty && File(hotwordsFilePath).existsSync()
          ? hotwordsFilePath
          : '';

  // Create recognizer (fresh — cannot reuse across isolate boundary)
  final recognizer = sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        whisper: sherpa.OfflineWhisperModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          language: 'cs',
          task: 'transcribe',
          tailPaddings: -1,
        ),
        tokens: tokensPath,
        numThreads: 4,
        debug: false,
        provider: 'cpu',
      ),
      hotwordsFile: resolvedHotwords,
      hotwordsScore: 1.5,
    ),
  );

  String transcribe(List<double> samples) {
    final stream = recognizer.createStream();
    stream.acceptWaveform(
      samples: Float32List.fromList(samples),
      sampleRate: sampleRate,
    );
    recognizer.decode(stream);
    final result = recognizer.getResult(stream);
    stream.free();
    return result.text.trim();
  }

  try {
    const int maxSinglePass = 30 * sampleRate;
    if (allSpeech.length <= maxSinglePass) {
      return transcribe(allSpeech);
    }

    const int chunkSize = 30 * sampleRate;
    const int overlap = 5 * sampleRate;
    final parts = <String>[];
    String prevTail = '';

    for (int start = 0;
        start < allSpeech.length;
        start += chunkSize - overlap) {
      final int end = min(start + chunkSize, allSpeech.length);
      final chunk = allSpeech.sublist(start, end);
      try {
        final text = transcribe(chunk);
        if (text.isEmpty) continue;
        final deduped = WhisperService.removeOverlap(prevTail, text);
        if (deduped.isNotEmpty) parts.add(deduped);
        prevTail = WhisperService.lastWords(text, 20);
      } catch (_) {}
    }

    return parts.join(' ');
  } finally {
    recognizer.free();
  }
}

/// Standalone VAD speech extraction for the Phase 2 one-shot isolate.
List<Float32List> _extractSpeechSegmentsStandalone(
  List<double> rawAudio,
  String vadModelPath,
  int sampleRate,
) {
  if (vadModelPath.isEmpty) {
    return [Float32List.fromList(rawAudio)];
  }

  final segments = <Float32List>[];
  try {
    final vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: vadModelPath,
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

    const int windowSize = 512;
    for (int i = 0; i < rawAudio.length; i += windowSize) {
      final int end = min(i + windowSize, rawAudio.length);
      final chunk = rawAudio.sublist(i, end);
      final Float32List padded;
      if (chunk.length < windowSize) {
        padded = Float32List(windowSize);
        for (int j = 0; j < chunk.length; j++) {
          padded[j] = chunk[j];
        }
      } else {
        padded = Float32List.fromList(chunk);
      }
      vad.acceptWaveform(padded);

      while (!vad.isEmpty()) {
        final segment = vad.front();
        vad.pop();
        if (segment.samples.isNotEmpty) {
          segments.add(segment.samples);
        }
      }
    }

    vad.flush();
    while (!vad.isEmpty()) {
      final segment = vad.front();
      vad.pop();
      if (segment.samples.isNotEmpty) {
        segments.add(segment.samples);
      }
    }

    vad.free();
  } catch (e) {
    return [Float32List.fromList(rawAudio)];
  }

  return segments;
}

/// A function that transcribes a list of float32 audio samples to text.
typedef AudioTranscriber = Future<String> Function(List<double> samples);

/// Manages on-device speech transcription with sliding-window buffering.
///
/// In production, all heavy work (VAD, Whisper decode) runs on a persistent
/// background isolate spawned in [loadModel]. The main isolate stays free
/// for UI rendering.
///
/// For unit tests, [WhisperService.withTranscriber] bypasses the worker
/// isolate and uses an injected transcriber function with local buffers.
class WhisperService {
  static const int _sampleRate = 16000;

  /// Number of new samples required before a window transcription is triggered.
  /// 5s windows keep per-call decode() freeze shorter while still giving
  /// Whisper enough context for decent Czech transcription.
  static const int _windowInterval = 5 * _sampleRate; // 5 seconds

  /// Overlap samples re-included in each window to preserve boundary words.
  static const int _overlapSamples = 3 * _sampleRate; // 3 seconds

  /// URL for Silero VAD model download.
  static const String _vadModelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx';

  /// Model configuration registry.
  static const WhisperModelConfig smallConfig = WhisperModelConfig(
    dirName: 'sherpa-onnx-whisper-small',
    encoderFile: 'small-encoder.int8.onnx',
    decoderFile: 'small-decoder.int8.onnx',
    tokensFile: 'small-tokens.txt',
    baseUrl:
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-small/resolve/main',
    displayName: 'Whisper Small',
    variant: 'INT8 (sherpa-onnx)',
    sizeMB: 358,
    expectedMinSizes: {
      'small-encoder.int8.onnx': 50 * 1024 * 1024,
      'small-decoder.int8.onnx': 50 * 1024 * 1024,
      'small-tokens.txt': 10 * 1024,
    },
  );

  static const WhisperModelConfig turboConfig = WhisperModelConfig(
    dirName: 'sherpa-onnx-whisper-turbo',
    encoderFile: 'turbo-encoder.int8.onnx',
    decoderFile: 'turbo-decoder.int8.onnx',
    tokensFile: 'turbo-tokens.txt',
    baseUrl:
        'https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/resolve/main',
    displayName: 'Whisper Large-v3-Turbo',
    variant: 'INT8 (sherpa-onnx)',
    sizeMB: 1036,
    expectedMinSizes: {
      'turbo-encoder.int8.onnx': 200 * 1024 * 1024,
      'turbo-decoder.int8.onnx': 50 * 1024 * 1024,
      'turbo-tokens.txt': 10 * 1024,
    },
  );

  /// Current model configuration.
  WhisperModelConfig _modelConfig = smallConfig;

  /// Human-readable model name (for UI display).
  static String get modelDisplayName => smallConfig.displayName;

  /// Model variant/quantization info.
  static String get modelVariant => smallConfig.variant;

  /// Get the current model config.
  WhisperModelConfig get modelConfig => _modelConfig;

  // ---------------------------------------------------------------------------
  // Worker isolate state (Phase 3 — production mode)
  // ---------------------------------------------------------------------------

  Isolate? _workerIsolate;
  SendPort? _workerSendPort;
  ReceivePort? _mainReceivePort;
  StreamSubscription<dynamic>? _workerSubscription;
  Completer<void>? _initCompleter;
  Completer<String>? _transcribeFullCompleter;
  Completer<String>? _transcribeTailCompleter;
  Completer<void>? _flushVadCompleter;
  Completer<List<double>>? _rawAudioCompleter;

  // ---------------------------------------------------------------------------
  // Local state (test mode via withTranscriber — no worker spawned)
  // ---------------------------------------------------------------------------

  /// Injectable transcribe function — set by [withTranscriber] for tests
  /// or by [loadModel] for web (no-op).
  AudioTranscriber? _transcriber;

  /// Accumulated speech-only audio buffer (VAD-filtered). Test mode only.
  final List<double> _speechBuffer = [];

  /// Raw audio buffer kept for transcribeFull(). Test mode only.
  final List<double> _rawAudioBuffer = [];

  /// Number of speech samples already transcribed in live windows. Test mode only.
  int _lastSpeechBoundary = 0;

  String _previousTailText = '';
  String _fullTranscript = '';
  bool _isTranscribing = false;

  // ---------------------------------------------------------------------------
  // Model paths (needed for download / verification on main isolate)
  // ---------------------------------------------------------------------------

  /// Path to the VAD model file.
  String _vadModelPath = '';

  /// Path to the medical hotwords file.
  String _hotwordsFilePath = '';

  /// Paths to model files (set during loadModel).
  String _encoderPath = '';
  String _decoderPath = '';
  String _tokensPath = '';

  final StreamController<String> _transcriptController =
      StreamController<String>.broadcast();

  /// Stream of incremental transcript updates during recording.
  Stream<String> get transcriptStream => _transcriptController.stream;

  /// Whether the model is ready for transcription.
  bool get isModelLoaded => _transcriber != null || _workerSendPort != null;

  /// Get the raw audio buffer for cloud transcription (test mode only).
  /// In production mode, the raw buffer lives in the worker isolate;
  /// the main isolate only has the test-mode local buffer.
  List<double> getRawAudioBuffer() =>
      List<double>.unmodifiable(_rawAudioBuffer);

  /// Production constructor — call [loadModel] before use.
  WhisperService();

  /// Test constructor — injects a custom [transcriber] function to avoid
  /// loading the real model in unit tests. Bypasses the worker isolate.
  WhisperService.withTranscriber(AudioTranscriber transcriber)
      : _transcriber = transcriber;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Check whether all model files exist and meet minimum size requirements.
  /// Returns true if model is ready to use, false if download is needed.
  static Future<bool> isModelDownloaded({WhisperModelConfig? config}) async {
    if (kIsWeb) return true;
    final c = config ?? smallConfig;
    final Directory docsDir = await getApplicationDocumentsDirectory();
    final String modelDir = '${docsDir.path}/${c.dirName}';
    // Check VAD model separately
    final vadFile = File('$modelDir/silero_vad.onnx');
    if (!await vadFile.exists() || await vadFile.length() < 300 * 1024) {
      debugLog('[WhisperService] VAD file missing or too small');
      return false;
    }
    for (final entry in c.expectedMinSizes.entries) {
      final file = File('$modelDir/${entry.key}');
      if (!await file.exists()) {
        debugLog('[WhisperService] File missing: ${entry.key}');
        return false;
      }
      final size = await file.length();
      if (size < entry.value) {
        debugLog('[WhisperService] File too small: ${entry.key} '
            '($size bytes, expected >= ${entry.value})');
        return false;
      }
    }
    return true;
  }

  /// Delete all model files (corrupted, partial, or outdated).
  static Future<void> deleteModelFiles({WhisperModelConfig? config}) async {
    if (kIsWeb) return;
    final c = config ?? smallConfig;
    final Directory docsDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${docsDir.path}/${c.dirName}');
    if (dir.existsSync()) {
      debugLog('[WhisperService] Deleting model directory: ${dir.path}');
      dir.deleteSync(recursive: true);
    }
  }

  /// Verify model files are valid and delete any that are corrupted/partial.
  /// Returns true if all files are intact, false if re-download is needed.
  Future<bool> _verifyAndCleanModel(String modelDir) async {
    bool allValid = true;
    // Verify VAD model
    final vadFile = File('$modelDir/silero_vad.onnx');
    if (!await vadFile.exists()) {
      debugLog('[WhisperService] Missing: silero_vad.onnx');
      allValid = false;
    } else if (await vadFile.length() < 300 * 1024) {
      debugLog('[WhisperService] Corrupted silero_vad.onnx. Deleting.');
      await vadFile.delete();
      allValid = false;
    }
    for (final entry in _modelConfig.expectedMinSizes.entries) {
      final file = File('$modelDir/${entry.key}');
      if (!await file.exists()) {
        debugLog('[WhisperService] Missing: ${entry.key}');
        allValid = false;
        continue;
      }
      final size = await file.length();
      if (size < entry.value) {
        debugLog('[WhisperService] Corrupted/partial ${entry.key}: '
            '$size bytes < ${entry.value} min. Deleting.');
        await file.delete();
        allValid = false;
      }
    }
    return allValid;
  }

  /// Copy the hotwords file from bundled assets to the model directory.
  Future<void> _copyHotwordsFile(String modelDir) async {
    final targetFile = File('$modelDir/hotwords_cs_medical.txt');
    if (await targetFile.exists()) return;
    try {
      final data =
          await rootBundle.loadString('assets/hotwords_cs_medical.txt');
      await targetFile.writeAsString(data);
      debugLog('[WhisperService] Hotwords file copied to model dir.');
    } catch (e) {
      debugLog('[WhisperService] Failed to copy hotwords file: $e');
    }
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
  /// On native platforms, spawns a persistent worker isolate that owns all
  /// sherpa_onnx FFI resources.
  Future<void> loadModel({WhisperModelConfig? config}) async {
    if (kIsWeb) {
      _transcriber = (_) async => '';
      return;
    }

    if (config != null) _modelConfig = config;

    debugLog('[WhisperService] loadModel() starting '
        '(${_modelConfig.displayName})...');

    final Directory docsDir = await getApplicationDocumentsDirectory();
    final String modelDir = '${docsDir.path}/${_modelConfig.dirName}';

    _encoderPath = '$modelDir/${_modelConfig.encoderFile}';
    _decoderPath = '$modelDir/${_modelConfig.decoderFile}';
    _tokensPath = '$modelDir/${_modelConfig.tokensFile}';
    _vadModelPath = '$modelDir/silero_vad.onnx';
    _hotwordsFilePath = '$modelDir/hotwords_cs_medical.txt';

    // Copy hotwords file from assets to model directory
    await _copyHotwordsFile(modelDir);

    // Verify existing files — delete corrupted/partial ones
    final bool intact = await _verifyAndCleanModel(modelDir);
    if (!intact) {
      debugLog('[WhisperService] Model files incomplete, downloading...');
      await _downloadModel(modelDir,
          config: _modelConfig, onProgress: _onDownloadProgress);
      // Verify again after download
      final bool ok = await _verifyAndCleanModel(modelDir);
      if (!ok) {
        throw Exception(
            'Model download failed: files still invalid after download');
      }
    }

    // --- Phase 3: Spawn persistent worker isolate ---
    debugLog('[WhisperService] Spawning worker isolate...');
    _mainReceivePort = ReceivePort();
    _workerIsolate = await Isolate.spawn(
      whisperWorkerEntryPoint,
      _mainReceivePort!.sendPort,
    );

    final workerSendPortCompleter = Completer<SendPort>();
    _initCompleter = Completer<void>();

    _workerSubscription = _mainReceivePort!.listen((dynamic message) {
      if (message is SendPort) {
        workerSendPortCompleter.complete(message);
        return;
      }
      _handleWorkerMessage(message);
    });

    _workerSendPort = await workerSendPortCompleter.future;

    // Send init command with model paths
    _workerSendPort!.send(<String, dynamic>{
      'cmd': 'init',
      'encoderPath': _encoderPath,
      'decoderPath': _decoderPath,
      'tokensPath': _tokensPath,
      'vadModelPath': _vadModelPath,
      'hotwordsFilePath': _hotwordsFilePath,
    });

    try {
      await _initCompleter!.future.timeout(const Duration(seconds: 30));
      _initCompleter = null;
      debugLog('[WhisperService] Worker isolate ready.');
    } on TimeoutException {
      debugLog('[WhisperService] Worker init TIMED OUT — killing isolate.');
      _killWorker();
      throw Exception(
          'Model init timed out (30s). Device may be low on memory.');
    } catch (e) {
      debugLog('[WhisperService] Worker init FAILED: $e — killing isolate.');
      _killWorker();
      // Don't delete model files — they may be intact; the failure
      // is likely transient (OOM / memory pressure).
      throw Exception('Model init failed: $e');
    }
  }

  /// Accept new audio [samples] from the microphone stream.
  ///
  /// In production mode, samples are sent to the worker isolate via
  /// [TransferableTypedData] for zero-copy transfer. The worker handles
  /// VAD filtering, buffering, and sliding-window transcription.
  ///
  /// In test mode (via [withTranscriber]), samples are buffered locally.
  void feedAudio(List<double> samples) {
    if (_workerSendPort != null) {
      // --- Phase 3: send to persistent worker isolate ---
      final float32 = Float32List.fromList(samples);
      _workerSendPort!.send(<String, dynamic>{
        'cmd': 'feedAudio',
        'samples': TransferableTypedData.fromList([float32]),
      });
      return;
    }

    // --- Test / web mode: local buffer management ---
    _rawAudioBuffer.addAll(samples);
    _speechBuffer.addAll(samples); // No VAD in test mode

    // Trigger transcription when enough speech has accumulated
    if (!_isTranscribing &&
        _speechBuffer.length - _lastSpeechBoundary >= _windowInterval) {
      _transcribeWindow();
    }
  }

  /// Transcribe all speech from the recording in a high-quality pass.
  ///
  /// In production mode, the worker isolate already owns the raw audio
  /// buffer. We simply send a command and await the result — the UI thread
  /// stays completely unblocked.
  ///
  /// In test mode, the local transcriber is called directly.
  Future<String> transcribeFull() async {
    if (_workerSendPort != null) {
      // --- Phase 3: ask worker isolate to transcribe ---
      debugLog('[WhisperService] transcribeFull → sending to worker');
      _transcribeFullCompleter = Completer<String>();
      _workerSendPort!.send(<String, dynamic>{'cmd': 'transcribeFull'});
      try {
        final result = await _transcribeFullCompleter!.future;
        _transcribeFullCompleter = null;
        debugLog(
            '[WhisperService] transcribeFull done: ${result.length} chars');
        return result;
      } catch (e) {
        _transcribeFullCompleter = null;
        debugLog('[WhisperService] transcribeFull error: $e');
        rethrow;
      }
    }

    // --- Test / web mode: local transcription ---
    if (_rawAudioBuffer.isEmpty) return '';
    debugLog('[WhisperService] transcribeFull (local): '
        '${_rawAudioBuffer.length} raw samples '
        '(${(_rawAudioBuffer.length / _sampleRate).toStringAsFixed(1)}s)');

    final result = await _runTranscriber(_rawAudioBuffer);
    debugLog('[WhisperService] transcribeFull done: ${result.length} chars');
    return result;
  }

  /// Transcribe using incremental chunks already decoded during recording,
  /// plus the remaining tail that hasn't been finalized yet.
  ///
  /// In production mode, the worker isolate tracked finalized chunk
  /// boundaries during recording. Only the un-finalized tail needs decoding
  /// now, making this much faster than [transcribeFull] for long recordings.
  ///
  /// In test mode, falls back to transcribing the full raw audio buffer.
  Future<String> transcribeTail() async {
    if (_workerSendPort != null) {
      debugLog('[WhisperService] transcribeTail → sending to worker');
      _transcribeTailCompleter = Completer<String>();
      _workerSendPort!.send(<String, dynamic>{'cmd': 'transcribeTail'});
      try {
        final result = await _transcribeTailCompleter!.future;
        _transcribeTailCompleter = null;
        debugLog(
            '[WhisperService] transcribeTail done: ${result.length} chars');
        return result;
      } catch (e) {
        _transcribeTailCompleter = null;
        debugLog('[WhisperService] transcribeTail error: $e');
        rethrow;
      }
    }

    // Test mode: no incremental chunking, transcribe everything
    if (_rawAudioBuffer.isEmpty) return '';
    debugLog('[WhisperService] transcribeTail (local): '
        '${_rawAudioBuffer.length} raw samples '
        '(${(_rawAudioBuffer.length / _sampleRate).toStringAsFixed(1)}s)');
    final result = await _runTranscriber(_rawAudioBuffer);
    debugLog('[WhisperService] transcribeTail done: ${result.length} chars');
    return result;
  }

  /// Clear all audio buffers and accumulated transcript state.
  void reset() {
    if (_workerSendPort != null) {
      _workerSendPort!.send(<String, dynamic>{'cmd': 'reset'});
      return;
    }
    // Test mode: clear local buffers
    _speechBuffer.clear();
    _rawAudioBuffer.clear();
    _lastSpeechBoundary = 0;
    _previousTailText = '';
    _fullTranscript = '';
    _isTranscribing = false;
  }

  /// Flush VAD internal buffers to ensure all pending speech segments
  /// are pushed into the speech buffer before final transcription.
  Future<void> flushVad() async {
    if (_workerSendPort != null) {
      debugLog('[WhisperService] flushVad → sending to worker');
      _flushVadCompleter = Completer<void>();
      _workerSendPort!.send(<String, dynamic>{'cmd': 'flush'});
      try {
        await _flushVadCompleter!.future.timeout(const Duration(seconds: 5));
      } catch (e) {
        debugLog('[WhisperService] flushVad timeout/error: $e');
      } finally {
        _flushVadCompleter = null;
      }
      return;
    }
    // Test mode: no-op (no VAD in test mode)
  }

  /// Retrieve the raw audio buffer from the worker isolate.
  /// Used in hybrid mode to send raw audio to cloud transcription.
  Future<List<double>> getRawAudioBufferFromWorker() async {
    if (_workerSendPort != null) {
      debugLog(
          '[WhisperService] getRawAudioBufferFromWorker → sending to worker');
      _rawAudioCompleter = Completer<List<double>>();
      _workerSendPort!.send(<String, dynamic>{'cmd': 'getRawAudio'});
      try {
        final result = await _rawAudioCompleter!.future
            .timeout(const Duration(seconds: 30));
        _rawAudioCompleter = null;
        debugLog('[WhisperService] getRawAudioBufferFromWorker: '
            '${result.length} samples '
            '(${(result.length / _sampleRate).toStringAsFixed(1)}s)');
        return result;
      } catch (e) {
        _rawAudioCompleter = null;
        debugLog('[WhisperService] getRawAudioBufferFromWorker error: $e');
        rethrow;
      }
    }

    // Test mode: return local buffer
    return List<double>.unmodifiable(_rawAudioBuffer);
  }

  /// Release all resources.
  void dispose() {
    _killWorker();
    // Clear test-mode buffers
    _speechBuffer.clear();
    _rawAudioBuffer.clear();
    _lastSpeechBoundary = 0;
    _previousTailText = '';
    _fullTranscript = '';
    _isTranscribing = false;
    if (!_transcriptController.isClosed) {
      _transcriptController.close();
    }
  }

  /// Switch to a different on-device model. Kills the current worker
  /// isolate and respawns with the new model config.
  Future<void> switchModel(WhisperModelConfig config) async {
    _killWorker();
    _speechBuffer.clear();
    _rawAudioBuffer.clear();
    _lastSpeechBoundary = 0;
    _previousTailText = '';
    _fullTranscript = '';
    _isTranscribing = false;
    await loadModel(config: config);
  }

  /// Terminate the worker isolate and clean up communication channels.
  void _killWorker() {
    if (_workerSendPort != null) {
      try {
        _workerSendPort!.send(<String, dynamic>{'cmd': 'dispose'});
      } catch (_) {
        // Worker may already be gone
      }
    }
    _workerSubscription?.cancel();
    _workerSubscription = null;
    _workerIsolate?.kill(priority: Isolate.immediate);
    _workerIsolate = null;
    _workerSendPort = null;
    _mainReceivePort?.close();
    _mainReceivePort = null;
    _initCompleter = null;
    _transcribeFullCompleter = null;
    _transcribeTailCompleter = null;
    _flushVadCompleter = null;
    _rawAudioCompleter = null;
  }

  /// Handle messages coming back from the worker isolate.
  void _handleWorkerMessage(dynamic message) {
    if (message is! Map) return;
    final type = message['type'] as String?;
    switch (type) {
      case 'initDone':
        _initCompleter?.complete();
      case 'initError':
        _initCompleter?.completeError(
            Exception(message['error'] as String? ?? 'Unknown worker error'));
      case 'transcript':
        final text = message['text'] as String? ?? '';
        if (!_transcriptController.isClosed) {
          _transcriptController.add(text);
        }
      case 'transcribeFullDone':
        _transcribeFullCompleter?.complete(message['text'] as String? ?? '');
      case 'transcribeFullError':
        _transcribeFullCompleter?.completeError(
            Exception(message['error'] as String? ?? 'Unknown worker error'));
      case 'transcribeTailDone':
        _transcribeTailCompleter?.complete(message['text'] as String? ?? '');
      case 'transcribeTailError':
        _transcribeTailCompleter?.completeError(
            Exception(message['error'] as String? ?? 'Unknown worker error'));
      case 'finalChunkDone':
        break; // informational — could expose for UI progress indicator
      case 'flushDone':
        _flushVadCompleter?.complete();
      case 'rawAudioData':
        final TransferableTypedData transferable =
            message['samples'] as TransferableTypedData;
        final ByteBuffer buffer = transferable.materialize();
        final Float32List samples = buffer.asFloat32List();
        _rawAudioCompleter?.complete(samples.toList());
      case 'resetDone':
        break; // fire-and-forget
      case 'disposeDone':
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Internal helpers (test / web mode only)
  // ---------------------------------------------------------------------------

  /// Sliding-window transcription — only used in test mode (withTranscriber).
  Future<void> _transcribeWindow() async {
    if (_isTranscribing) return;
    if (_speechBuffer.length - _lastSpeechBoundary < _windowInterval) return;
    _isTranscribing = true;

    try {
      final int overlapStart = max(0, _lastSpeechBoundary - _overlapSamples);
      // Snapshot the buffer end BEFORE the async call so we don't skip audio
      // that arrives while we're transcribing.
      final int windowEnd = _speechBuffer.length;
      final List<double> window =
          List<double>.from(_speechBuffer.sublist(overlapStart, windowEnd));

      // No RMS silence check needed — VAD already filtered silence.

      final String rawText = await _runTranscriber(window);
      if (rawText.isEmpty) {
        _lastSpeechBoundary = windowEnd;
        return;
      }

      final String deduped = removeOverlap(_previousTailText, rawText);
      if (deduped.isNotEmpty) {
        _fullTranscript =
            _fullTranscript.isEmpty ? deduped : '$_fullTranscript $deduped';
      }

      _previousTailText = lastWords(rawText, 20);
      _lastSpeechBoundary = windowEnd;

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

  /// Download model files from HuggingFace.
  /// Downloads to a temp file first, then renames — so partial downloads
  /// never leave a "valid-looking" file on disk.
  static Future<void> _downloadModel(
    String modelDir, {
    required WhisperModelConfig config,
    void Function(String fileName, double progress)? onProgress,
  }) async {
    final dir = Directory(modelDir);
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }

    final files = {
      config.encoderFile: '${config.baseUrl}/${config.encoderFile}',
      config.decoderFile: '${config.baseUrl}/${config.decoderFile}',
      config.tokensFile: '${config.baseUrl}/${config.tokensFile}',
      'silero_vad.onnx': _vadModelUrl,
    };

    final expectedMinSizes = <String, int>{
      ...config.expectedMinSizes,
      'silero_vad.onnx': 300 * 1024,
    };

    final httpClient = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 30);
    try {
      int fileIndex = 0;
      for (final entry in files.entries) {
        final filePath = '$modelDir/${entry.key}';
        final file = File(filePath);

        // Skip if already downloaded and valid size
        if (file.existsSync()) {
          final minSize = expectedMinSizes[entry.key] ?? 0;
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

        // Retry each file download up to 3 times with exponential backoff
        const int maxRetries = 3;
        for (int attempt = 1; attempt <= maxRetries; attempt++) {
          try {
            debugLog('[WhisperService] Downloading ${entry.key}... '
                '(attempt $attempt/$maxRetries)');
            final request = await httpClient.getUrl(Uri.parse(entry.value));
            final response = await request.close();

            if (response.statusCode >= 200 && response.statusCode < 400) {
              final contentLength = response.contentLength;
              final sink = tmpFile.openWrite();
              int received = 0;

              // Use a timeout-per-chunk approach: if no data arrives
              // within 60s the download is considered stalled.
              await for (final chunk
                  in response.timeout(const Duration(seconds: 60))) {
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
              final minSize = expectedMinSizes[entry.key] ?? 0;
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
              break; // Success — exit retry loop
            } else {
              throw Exception(
                'Failed to download ${entry.key}: HTTP ${response.statusCode}',
              );
            }
          } catch (e) {
            // Clean up partial temp file
            if (tmpFile.existsSync()) {
              try {
                tmpFile.deleteSync();
              } catch (_) {}
            }
            if (attempt == maxRetries) {
              debugLog('[WhisperService] ${entry.key} failed after '
                  '$maxRetries attempts: $e');
              rethrow;
            }
            final delay = Duration(seconds: attempt * 2); // 2s, 4s, 6s
            debugLog('[WhisperService] ${entry.key} attempt $attempt failed: '
                '$e — retrying in ${delay.inSeconds}s...');
            await Future<void>.delayed(delay);
          }
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

  static String lastWords(String text, int n) {
    final List<String> words =
        text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.length <= n) return text;
    return words.sublist(words.length - n).join(' ');
  }
}
