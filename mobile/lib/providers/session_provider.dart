import 'dart:async';

import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../config/constants.dart';
import '../models/recording_entry.dart';
import '../models/session_state.dart';
import '../services/audio_service.dart';
import '../services/cloud_transcription_service.dart';
import '../services/recording_storage_service.dart';
import '../services/report_service.dart';
import '../services/whisper_service.dart';
import 'recording_history_provider.dart';

final reportServiceProvider = Provider<ReportService>((ref) {
  return ReportService();
});

final audioServiceProvider = Provider<AudioService>((ref) {
  return AudioService();
});

final whisperServiceProvider = Provider<WhisperService>((ref) {
  return WhisperService();
});

final cloudTranscriptionServiceProvider =
    Provider<CloudTranscriptionService>((ref) {
  return CloudTranscriptionService();
});

/// Provides the persisted transcription model preference.
final transcriptionModelProvider =
    StateNotifierProvider<TranscriptionModelNotifier, TranscriptionModel>(
        (ref) {
  return TranscriptionModelNotifier();
});

class TranscriptionModelNotifier extends StateNotifier<TranscriptionModel> {
  TranscriptionModelNotifier() : super(TranscriptionModel.small) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(AppConstants.transcriptionModelPrefKey);
    state = TranscriptionModelApi.fromString(value);
  }

  Future<void> setModel(TranscriptionModel model) async {
    state = model;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        AppConstants.transcriptionModelPrefKey, model.prefValue);
  }
}

/// Whether automatic email report sending is enabled.
final emailReportEnabledProvider =
    StateNotifierProvider<EmailReportEnabledNotifier, bool>((ref) {
  return EmailReportEnabledNotifier();
});

class EmailReportEnabledNotifier extends StateNotifier<bool> {
  EmailReportEnabledNotifier() : super(false) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getBool(AppConstants.emailReportEnabledPrefKey) ?? false;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(AppConstants.emailReportEnabledPrefKey, enabled);
  }
}

/// The email address to send reports to.
final emailReportAddressProvider =
    StateNotifierProvider<EmailReportAddressNotifier, String>((ref) {
  return EmailReportAddressNotifier();
});

class EmailReportAddressNotifier extends StateNotifier<String> {
  EmailReportAddressNotifier() : super('') {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = prefs.getString(AppConstants.emailReportAddressPrefKey) ?? '';
  }

  Future<void> setAddress(String address) async {
    state = address;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.emailReportAddressPrefKey, address);
  }
}

/// Provides the persisted visit type preference.
final visitTypeProvider =
    StateNotifierProvider<VisitTypeNotifier, VisitType>((ref) {
  return VisitTypeNotifier();
});

class VisitTypeNotifier extends StateNotifier<VisitType> {
  VisitTypeNotifier() : super(VisitType.defaultType) {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(AppConstants.visitTypePrefKey);
    state = VisitTypeApi.fromString(value);
  }

  Future<void> setVisitType(VisitType type) async {
    state = type;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(AppConstants.visitTypePrefKey, type.apiValue);
  }
}

final sessionProvider =
    StateNotifierProvider<SessionNotifier, SessionState>((ref) {
  return SessionNotifier(
    ref.watch(reportServiceProvider),
    ref.watch(audioServiceProvider),
    ref.watch(whisperServiceProvider),
    ref.watch(recordingStorageServiceProvider),
    ref,
  );
});

class SessionNotifier extends StateNotifier<SessionState> {
  final ReportService _reportService;
  final AudioService _audioService;
  final WhisperService _whisperService;
  final RecordingStorageService _storageService;
  final Ref _ref;

  StreamSubscription<List<double>>? _audioSubscription;
  StreamSubscription<String>? _transcriptSubscription;
  Timer? _reportTimer;
  Timer? _preloadTimer;
  Timer? _autoSaveTimer;

  /// Tracks the transcript text that was last sent for report generation.
  /// When the timer fires, we skip the API call if the transcript hasn't
  /// changed since the last report request (avoids wasteful duplicate calls).
  String _lastReportedTranscript = '';

  /// Tracks the last auto-saved transcript to avoid redundant writes.
  String _lastAutoSavedTranscript = '';

  bool _isPreloading = false;

  /// Timestamp when recording started — used to compute duration.
  DateTime? _recordingStartTime;

  SessionNotifier(
    this._reportService,
    this._audioService,
    this._whisperService,
    this._storageService,
    this._ref,
  ) : super(const SessionState()) {
    // Kick off model download / load immediately so it's ready when the
    // user presses record.  The OOM crashes were caused by beam search
    // (now removed), not by the preload timing.
    _preloadModel();
  }

  /// Read the current visit type API string from SharedPreferences.
  Future<String> _getVisitTypeApi() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString(AppConstants.visitTypePrefKey);
    return VisitTypeApi.fromString(value).apiValue;
  }

  /// Maximum auto-retry attempts for model preload.
  static const int _maxPreloadRetries = 3;

  /// Start downloading / loading the model in the background on app start.
  /// Automatically retries up to [_maxPreloadRetries] times on network errors
  /// with exponential backoff (5s, 10s, 20s).
  Future<void> _preloadModel({int attempt = 1}) async {
    if (_whisperService.isModelLoaded || _isPreloading) return;
    _isPreloading = true;
    try {
      // Check model integrity first
      final bool alreadyDownloaded = await WhisperService.isModelDownloaded();
      WhisperService.debugLog(
          '[SessionNotifier] Model already downloaded: $alreadyDownloaded');

      if (!alreadyDownloaded) {
        // Show a progress indicator right away (0%) so user sees activity
        if (mounted) {
          state = state.copyWith(
            modelDownloadProgress: 0.0,
            modelDownloadFileName: 'kontrola modelu...',
            clearError: true,
          );
        }
      }

      _whisperService.onDownloadProgress = (String fileName, double progress) {
        if (!mounted) return;
        state = state.copyWith(
          modelDownloadProgress: progress,
          modelDownloadFileName: fileName,
        );
      };
      await _whisperService.loadModel();
      _whisperService.onDownloadProgress = null;
      if (!mounted) return;
      WhisperService.debugLog('[SessionNotifier] Model loaded successfully.');
      state = state.copyWith(isModelLoaded: true, clearDownload: true);
    } catch (e) {
      _whisperService.onDownloadProgress = null;
      WhisperService.debugLog(
          '[SessionNotifier] Model load error (attempt $attempt): $e');
      if (!mounted) return;

      // Auto-retry with exponential backoff on any recoverable error
      // (network errors, OOM, native init failure).
      if (attempt < _maxPreloadRetries) {
        final delay =
            Duration(seconds: 5 * (1 << (attempt - 1))); // 5s, 10s, 20s
        WhisperService.debugLog(
            '[SessionNotifier] Preload error — retrying in ${delay.inSeconds}s '
            '(attempt ${attempt + 1}/$_maxPreloadRetries)...');
        state = state.copyWith(
          clearDownload: true,
          errorMessage:
              'Načítání modelu selhalo. Automatický pokus za ${delay.inSeconds}s...',
        );
        _isPreloading = false;
        await Future<void>.delayed(delay);
        if (!mounted) return;
        // Clear error before retry
        state = state.copyWith(clearError: true);
        return _preloadModel(attempt: attempt + 1);
      }

      final bool isNetworkError = _isNetworkException(e);
      state = state.copyWith(
        clearDownload: true,
        errorMessage: isNetworkError
            ? 'Stahování modelu selhalo. Zkontrolujte internet a stiskněte tlačítko níže.'
            : 'Chyba modelu: $e',
      );
    } finally {
      _isPreloading = false;
    }
  }

  /// Check if an exception is network-related.
  bool _isNetworkException(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('connection closed') ||
        msg.contains('connection refused') ||
        msg.contains('connection reset') ||
        msg.contains('connection timed out') ||
        msg.contains('network') ||
        msg.contains('socket') ||
        msg.contains('nodename nor servname') ||
        msg.contains('no address associated') ||
        msg.contains('host not found') ||
        msg.contains('dns') ||
        msg.contains('unreachable') ||
        msg.contains('timed out') ||
        msg.contains('httpclient');
  }

  /// Allow user to manually retry model loading after a failure.
  void retryModelLoad() {
    if (_whisperService.isModelLoaded || _isPreloading) return;
    state = state.copyWith(clearError: true, clearDownload: true);
    _preloadModel();
  }

  /// Preload the Whisper model in background so first recording starts
  /// instantly. Safe to call multiple times — no-op if already loaded.
  /// Called from HomeScreen after first frame renders.
  Future<void> preloadModel() async {
    final selectedModel = _ref.read(transcriptionModelProvider);
    if (selectedModel == TranscriptionModel.cloud) return;

    final config = selectedModel == TranscriptionModel.turbo
        ? WhisperService.turboConfig
        : WhisperService.smallConfig;

    if (_whisperService.isModelLoaded &&
        _whisperService.modelConfig.dirName == config.dirName) {
      return;
    }

    if (_isPreloading) return;

    // Delegate to the internal preload (with retry logic)
    await _preloadModel();
  }

  /// Switch to a different on-device model. Downloads if needed, then loads.
  ///
  /// Called from the settings screen when the user selects a different model.
  /// For cloud mode, just unloads the on-device model (no download needed).
  Future<void> switchToModel(TranscriptionModel model) async {
    if (state.status == RecordingStatus.recording ||
        state.status == RecordingStatus.processing) {
      return; // Don't switch while recording
    }
    if (_isPreloading) return;

    if (model == TranscriptionModel.cloud) {
      // Cloud mode doesn't need an on-device model loaded
      state = state.copyWith(
          isModelLoaded: true, clearDownload: true, clearError: true);
      return;
    }

    // Hybrid uses small model for live preview
    final config = (model == TranscriptionModel.turbo)
        ? WhisperService.turboConfig
        : WhisperService.smallConfig;

    // If this model is already loaded, nothing to do
    if (_whisperService.isModelLoaded &&
        _whisperService.modelConfig.dirName == config.dirName) {
      return;
    }

    _isPreloading = true;
    state = state.copyWith(
      isModelLoaded: false,
      modelDownloadProgress: 0.0,
      modelDownloadFileName: 'kontrola modelu...',
      clearError: true,
    );

    _whisperService.onDownloadProgress = (String fileName, double progress) {
      if (!mounted) return;
      state = state.copyWith(
        modelDownloadProgress: progress,
        modelDownloadFileName: fileName,
      );
    };

    try {
      if (_whisperService.isModelLoaded) {
        await _whisperService.switchModel(config);
      } else {
        await _whisperService.loadModel(config: config);
      }
      _whisperService.onDownloadProgress = null;
      if (!mounted) return;
      WhisperService.debugLog(
          '[SessionNotifier] Switched to ${config.displayName}');
      state = state.copyWith(isModelLoaded: true, clearDownload: true);
    } catch (e) {
      _whisperService.onDownloadProgress = null;
      WhisperService.debugLog('[SessionNotifier] Model switch error: $e');
      if (!mounted) return;
      final isNetwork = _isNetworkException(e);
      state = state.copyWith(
        clearDownload: true,
        errorMessage: isNetwork
            ? 'Stahování modelu selhalo. Zkontrolujte internet.'
            : 'Chyba modelu: $e',
      );
    } finally {
      _isPreloading = false;
    }
  }

  // ---------------------------------------------------------------------------
  // Wake lock & foreground service helpers
  // ---------------------------------------------------------------------------

  /// Initialise the foreground task notification channel (call once).
  static bool _foregroundTaskInitialised = false;

  void _initForegroundTask() {
    if (_foregroundTaskInitialised) return;
    _foregroundTaskInitialised = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'anote_recording',
        channelName: 'ANOTE nahrávání',
        channelDescription: 'Probíhá nahrávání lékařské konzultace.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: false,
      ),
    );
  }

  /// Keep the screen on and start a foreground service so recording survives
  /// the screen turning off.
  Future<void> _acquireWakeLockAndForeground() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      WhisperService.debugLog('[SessionNotifier] WakeLock enable error: $e');
    }
    try {
      _initForegroundTask();
      await FlutterForegroundTask.startService(
        notificationTitle: 'ANOTE — nahrávání',
        notificationText: 'Probíhá nahrávání lékařské konzultace.',
      );
    } catch (e) {
      WhisperService.debugLog(
          '[SessionNotifier] ForegroundTask start error: $e');
    }
  }

  /// Release wake lock and stop the foreground service.
  Future<void> _releaseWakeLockAndForeground() async {
    try {
      await WakelockPlus.disable();
    } catch (e) {
      WhisperService.debugLog('[SessionNotifier] WakeLock disable error: $e');
    }
    try {
      await FlutterForegroundTask.stopService();
    } catch (e) {
      WhisperService.debugLog(
          '[SessionNotifier] ForegroundTask stop error: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Recording pipeline
  // ---------------------------------------------------------------------------

  /// Begin recording.
  ///
  /// Sets status to [RecordingStatus.recording] immediately, then asynchronously:
  /// 1. Loads the Whisper model if not already loaded.
  /// 2. Starts [AudioService] (requests mic permission).
  /// 3. Pipes audio samples into [WhisperService].
  /// 4. Subscribes to live transcript updates.
  /// 5. Starts a periodic timer that generates report previews.
  void startRecording() {
    _recordingStartTime = DateTime.now();
    // Clear any loaded recording reference since this is a new session
    _ref.read(loadedRecordingIdProvider.notifier).state = null;
    state = state.copyWith(
      status: RecordingStatus.recording,
      transcript: '',
      report: '',
      clearError: true,
    );
    _startRecordingAsync();
  }

  Future<void> _startRecordingAsync() async {
    try {
      final selectedModel = _ref.read(transcriptionModelProvider);

      // ===== STEP 1: Start audio capture IMMEDIATELY =====
      // Pre-buffer audio while model loads so we don't lose the first seconds.
      await _audioService.start();
      if (!mounted || state.status != RecordingStatus.recording) return;

      final List<List<double>> preBuffer = [];
      StreamSubscription<List<double>>? preBufferSub;

      preBufferSub = _audioService.audioStream.listen(
        (List<double> samples) => preBuffer.add(samples),
      );

      // ===== STEP 2: Load model (if needed) =====
      // Cloud mode doesn't need on-device model
      // Hybrid mode uses small model for live preview
      if (selectedModel != TranscriptionModel.cloud) {
        final config = selectedModel == TranscriptionModel.turbo
            ? WhisperService.turboConfig
            : WhisperService.smallConfig; // hybrid uses small for live preview

        // Check if the correct model is loaded
        final needsSwitch = _whisperService.isModelLoaded &&
            _whisperService.modelConfig.dirName != config.dirName;

        if (needsSwitch || !_whisperService.isModelLoaded) {
          if (!_isPreloading) {
            _isPreloading = true;
            _whisperService.onDownloadProgress =
                (String fileName, double progress) {
              if (!mounted) return;
              state = state.copyWith(
                modelDownloadProgress: progress,
                modelDownloadFileName: fileName,
              );
            };
            try {
              if (needsSwitch) {
                await _whisperService.switchModel(config);
              } else {
                await _whisperService.loadModel(config: config);
              }
            } catch (e) {
              _whisperService.onDownloadProgress = null;
              _isPreloading = false;
              await preBufferSub.cancel();
              if (!mounted) return;
              final isNetwork = _isNetworkException(e);
              state = state.copyWith(
                status: RecordingStatus.idle,
                clearDownload: true,
                errorMessage: isNetwork
                    ? 'Model nelze stáhnout. Zkontrolujte připojení k internetu.'
                    : 'Chyba modelu: $e',
              );
              return;
            }
            _whisperService.onDownloadProgress = null;
            _isPreloading = false;
            if (!mounted) {
              await preBufferSub.cancel();
              return;
            }
            state = state.copyWith(isModelLoaded: true, clearDownload: true);
          } else {
            // Wait for the ongoing preload to finish.
            while (_isPreloading && mounted) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }
            if (!mounted || !_whisperService.isModelLoaded) {
              await preBufferSub.cancel();
              if (mounted) {
                state = state.copyWith(
                  status: RecordingStatus.idle,
                  errorMessage: 'Model se nepodařilo načíst. Zkuste to znovu.',
                );
              }
              return;
            }
          }
        }
      }

      // Abort if stopRecording() or resetSession() was called while we were
      // waiting for loadModel() or audioService.start().
      if (!mounted || state.status != RecordingStatus.recording) {
        await preBufferSub.cancel();
        return;
      }

      // ===== STEP 3: Cancel pre-buffer, flush into whisper, set up real pipeline =====
      await preBufferSub.cancel();

      // Flush pre-buffered audio into whisper service
      for (final samples in preBuffer) {
        _whisperService.feedAudio(samples);
      }
      preBuffer.clear();

      // Keep screen on and start foreground service so recording survives
      // the screen turning off.
      await _acquireWakeLockAndForeground();

      _audioSubscription = _audioService.audioStream.listen(
        (List<double> samples) => _whisperService.feedAudio(samples),
        onError: (Object error) {
          if (!mounted) return;
          state = state.copyWith(
            status: RecordingStatus.idle,
            errorMessage: 'Chyba mikrofonu: $error',
          );
        },
      );

      _transcriptSubscription = _whisperService.transcriptStream.listen(
        (String transcript) {
          if (!mounted) return;
          if (state.status == RecordingStatus.recording) {
            state = state.copyWith(transcript: transcript);
          }
        },
      );

      _reportTimer = Timer.periodic(
        AppConstants.reportGenerationInterval,
        (_) => _generateReportPreview(),
      );

      // Periodic auto-save every 10s so data survives app closure
      _lastAutoSavedTranscript = '';
      _autoSaveTimer = Timer.periodic(
        const Duration(seconds: 10),
        (_) => _periodicAutoSave(),
      );
    } catch (e) {
      if (!mounted) return;
      await _releaseWakeLockAndForeground();
      state = state.copyWith(
        status: RecordingStatus.idle,
        errorMessage: e.toString(),
      );
    }
  }

  Future<void> _generateReportPreview() async {
    if (!mounted) return;
    final String transcript = state.transcript;
    if (transcript.isEmpty || state.status != RecordingStatus.recording) {
      return;
    }
    // Skip if the transcript hasn't changed since the last report request.
    if (transcript == _lastReportedTranscript) return;
    _lastReportedTranscript = transcript;
    try {
      final vt = await _getVisitTypeApi();
      final String report =
          await _reportService.generateReport(transcript, visitType: vt);
      if (mounted && state.status == RecordingStatus.recording) {
        state = state.copyWith(report: report);
      }
    } catch (_) {
      // Silently ignore report errors during recording so the doctor is
      // not interrupted.  The final report on stop will surface errors.
    }
  }

  /// Stop recording and produce the final high-quality transcript and report.
  void stopRecording() {
    _reportTimer?.cancel();
    _reportTimer = null;

    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;

    // DON'T cancel audio subscription yet — let it drain
    _transcriptSubscription?.cancel();
    _transcriptSubscription = null;

    state = state.copyWith(status: RecordingStatus.processing);
    _stopRecordingAsync();
  }

  Future<void> _stopRecordingAsync() async {
    try {
      // Step 1: Stop the microphone (no new audio will be generated)
      WhisperService.debugLog('[SessionNotifier] Stopping audio service...');
      await _audioService.stop();

      // Step 2: Small delay to let in-flight audio buffers arrive
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // Step 3: NOW cancel the audio subscription (all pending buffers processed)
      await _audioSubscription?.cancel();
      _audioSubscription = null;

      // Release wake lock and foreground service now that audio capture is done.
      await _releaseWakeLockAndForeground();
      if (!mounted) return;

      // Flush VAD before final transcription to push pending speech segments
      await _whisperService.flushVad();

      final selectedModel = _ref.read(transcriptionModelProvider);

      WhisperService.debugLog('[SessionNotifier] Running transcribeFull...');
      String fullTranscript = '';

      if (selectedModel == TranscriptionModel.cloud) {
        // Cloud mode: use Azure OpenAI Whisper API
        try {
          final cloudService = _ref.read(cloudTranscriptionServiceProvider);
          // Get raw audio from whisper service's buffer via transcribeFull
          // The whisper service was still collecting audio for live preview
          fullTranscript = await cloudService
              .transcribe(_whisperService.getRawAudioBuffer());
        } catch (e) {
          WhisperService.debugLog(
              '[SessionNotifier] Cloud transcription error: $e');
          // Fall back to on-device transcription
          try {
            fullTranscript = await _whisperService.transcribeFull();
          } catch (e2) {
            WhisperService.debugLog(
                '[SessionNotifier] On-device fallback error: $e2');
          }
        }
      } else if (selectedModel == TranscriptionModel.hybrid) {
        // Hybrid mode: get raw audio from worker isolate, send to cloud
        try {
          final rawAudio = await _whisperService.getRawAudioBufferFromWorker();
          if (rawAudio.isNotEmpty) {
            final cloudService = _ref.read(cloudTranscriptionServiceProvider);
            fullTranscript = await cloudService.transcribe(rawAudio);
          }
        } catch (e) {
          WhisperService.debugLog(
              '[SessionNotifier] Hybrid cloud transcription error: $e');
          // Fallback to on-device transcribeTail if cloud fails
          try {
            fullTranscript = await _whisperService.transcribeTail();
          } catch (e2) {
            WhisperService.debugLog(
                '[SessionNotifier] Hybrid on-device fallback error: $e2');
          }
        }
      } else {
        try {
          fullTranscript = await _whisperService.transcribeTail();
        } catch (e) {
          WhisperService.debugLog('[SessionNotifier] transcribeTail error: $e');
          // Fall back to the live transcript instead of crashing
        }
      }
      if (!mounted) return;

      if (fullTranscript.isNotEmpty) {
        state = state.copyWith(transcript: fullTranscript);
      }

      final String finalTranscript = state.transcript;
      WhisperService.debugLog('[SessionNotifier] Final transcript length: '
          '${finalTranscript.length}');

      if (finalTranscript.isNotEmpty) {
        WhisperService.debugLog('[SessionNotifier] Generating report...');
        final vt = await _getVisitTypeApi();
        String? report;
        Object? lastError;
        for (int attempt = 1; attempt <= 3; attempt++) {
          try {
            report = await _reportService.generateReport(finalTranscript,
                visitType: vt);
            break;
          } catch (e) {
            lastError = e;
            WhisperService.debugLog(
                '[SessionNotifier] Report attempt $attempt failed: $e');
            if (attempt < 3) {
              await Future<void>.delayed(Duration(seconds: attempt * 3));
            }
          }
        }
        if (!mounted) return;
        if (report != null && report.isNotEmpty) {
          state = state.copyWith(report: report, visitTypeChanged: false);
          WhisperService.debugLog('[SessionNotifier] Report generated OK.');
          _sendEmailIfEnabled(report);
        } else if (lastError != null) {
          state = state.copyWith(errorMessage: lastError.toString());
        }
      }

      // --- Auto-save to recording history ---
      await _autoSaveRecording();
    } catch (e) {
      WhisperService.debugLog(
          '[SessionNotifier] _stopRecordingAsync error: $e');
      if (!mounted) return;
      state = state.copyWith(errorMessage: e.toString());
      // Still try to auto-save even on error (transcript may exist)
      await _autoSaveRecording();
    } finally {
      if (mounted) {
        WhisperService.debugLog('[SessionNotifier] Setting status to idle.');
        state = state.copyWith(status: RecordingStatus.idle);
      }
    }
  }

  /// Persist the current session to on-device storage if transcript is
  /// non-empty.  Called automatically at the end of [_stopRecordingAsync]
  /// and periodically during recording.
  ///
  /// If the session was already saved (loadedRecordingIdProvider is set),
  /// updates the existing entry instead of creating a new one.
  Future<void> _autoSaveRecording() async {
    if (!mounted) return;
    final transcript = state.transcript;
    if (transcript.isEmpty) return;

    try {
      final durationSeconds = _recordingStartTime != null
          ? DateTime.now().difference(_recordingStartTime!).inSeconds
          : 0;
      final vt = await _getVisitTypeApi();
      final existingId = _ref.read(loadedRecordingIdProvider);

      if (existingId != null) {
        // Update existing entry
        final existing = await _storageService.loadEntry(existingId);
        final updated = RecordingEntry(
          id: existingId,
          createdAt: existing.createdAt,
          transcript: transcript,
          report: state.report,
          visitType: vt,
          durationSeconds: durationSeconds,
          wordCount: transcript.trim().split(RegExp(r'\s+')).length,
          updatedAt: DateTime.now(),
        );
        await _storageService.saveEntry(updated);
        _ref.read(recordingIndexProvider.notifier).refresh();
        WhisperService.debugLog(
            '[SessionNotifier] Recording updated: $existingId');
      } else {
        // Create new entry
        final entry = RecordingEntry(
          id: RecordingStorageService.generateId(),
          createdAt: _recordingStartTime ?? DateTime.now(),
          transcript: transcript,
          report: state.report,
          visitType: vt,
          durationSeconds: durationSeconds,
          wordCount: transcript.trim().split(RegExp(r'\s+')).length,
        );
        await _storageService.saveEntry(entry);
        _ref.read(recordingIndexProvider.notifier).refresh();
        _ref.read(loadedRecordingIdProvider.notifier).state = entry.id;
        WhisperService.debugLog(
            '[SessionNotifier] Recording auto-saved: ${entry.id}');
      }
    } catch (e) {
      WhisperService.debugLog('[SessionNotifier] Auto-save failed: $e');
    }
  }

  /// Called every 10s during recording to persist progress.
  Future<void> _periodicAutoSave() async {
    if (!mounted || state.status != RecordingStatus.recording) return;
    final transcript = state.transcript;
    if (transcript.isEmpty) return;
    // Skip if nothing changed since last save
    if (transcript == _lastAutoSavedTranscript) return;
    _lastAutoSavedTranscript = transcript;
    await _autoSaveRecording();
  }

  // ---------------------------------------------------------------------------
  // Session management
  // ---------------------------------------------------------------------------

  /// Save the current session to history (if it has content) and start fresh.
  ///
  /// If the session was loaded from history, updates that entry's report.
  /// If it's a new unsaved session, creates a new history entry.
  /// Then resets to a clean state.
  Future<void> startNewRecording() async {
    final transcript = state.transcript;
    final report = state.report;
    final loadedId = _ref.read(loadedRecordingIdProvider);

    if (transcript.isNotEmpty || report.isNotEmpty) {
      try {
        if (loadedId != null) {
          // Already in history — update the report in case it was edited
          if (report.isNotEmpty) {
            await _storageService.updateReport(loadedId, report);
            _ref.read(recordingIndexProvider.notifier).refresh();
          }
        } else {
          // New session not yet in history — save it
          await _autoSaveRecording();
        }
      } catch (e) {
        WhisperService.debugLog(
            '[SessionNotifier] Save before new recording failed: $e');
      }
    }

    resetSession();
  }

  /// Clear all session state and stop any running audio/timers.
  void resetSession() {
    _reportTimer?.cancel();
    _reportTimer = null;

    _autoSaveTimer?.cancel();
    _autoSaveTimer = null;

    _audioSubscription?.cancel();
    _audioSubscription = null;

    _transcriptSubscription?.cancel();
    _transcriptSubscription = null;

    final bool wasRunning = state.status == RecordingStatus.recording ||
        state.status == RecordingStatus.processing;

    _whisperService.reset();
    _lastReportedTranscript = '';
    _recordingStartTime = null;
    _ref.read(loadedRecordingIdProvider.notifier).state = null;
    state = const SessionState();

    if (wasRunning) {
      // Fire-and-forget: we've already cleared state; we just want hardware to
      // stop.  Errors here are non-critical.
      _audioService.stop();
      _releaseWakeLockAndForeground();
    }
  }

  /// Load a recording from history into the current session.
  ///
  /// Sets the transcript and report from the saved entry so they are
  /// displayed in [TranscriptPanel] and [ReportPanel].
  void loadRecording(RecordingEntry entry) {
    _reportTimer?.cancel();
    _reportTimer = null;
    _audioSubscription?.cancel();
    _audioSubscription = null;
    _transcriptSubscription?.cancel();
    _transcriptSubscription = null;

    _whisperService.reset();
    _lastReportedTranscript = '';
    _recordingStartTime = null;

    _ref.read(loadedRecordingIdProvider.notifier).state = entry.id;
    state = SessionState(
      status: RecordingStatus.idle,
      transcript: entry.transcript,
      report: entry.report,
      isModelLoaded: state.isModelLoaded,
    );
  }

  /// Mark that the visit type was changed (show regenerate button).
  void markVisitTypeChanged() {
    if (state.report.isNotEmpty) {
      state = state.copyWith(visitTypeChanged: true);
    }
  }

  /// Regenerate the report using the current transcript and visit type.
  /// Retries up to 3 times with backoff to handle cold starts.
  Future<void> regenerateReport() async {
    final transcript = state.transcript;
    if (transcript.isEmpty) return;

    state = state.copyWith(
      status: RecordingStatus.processing,
      clearError: true,
      visitTypeChanged: false,
    );

    final vt = await _getVisitTypeApi();
    Object? lastError;
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final String report =
            await _reportService.generateReport(transcript, visitType: vt);
        if (!mounted) return;
        state = state.copyWith(
          status: RecordingStatus.idle,
          report: report,
        );
        _sendEmailIfEnabled(report);
        return;
      } catch (e) {
        lastError = e;
        WhisperService.debugLog(
            '[SessionNotifier] regenerateReport attempt $attempt failed: $e');
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: attempt * 3));
        }
      }
    }
    if (!mounted) return;
    state = state.copyWith(
      status: RecordingStatus.idle,
      errorMessage: lastError.toString(),
    );
  }

  /// Send report via email if the feature is enabled and configured.
  /// Fire-and-forget — errors are logged, never shown to user.
  Future<void> _sendEmailIfEnabled(String report) async {
    try {
      final enabled = _ref.read(emailReportEnabledProvider);
      if (!enabled) return;

      final email = _ref.read(emailReportAddressProvider);
      if (email.isEmpty) return;

      final vt = await _getVisitTypeApi();
      await _reportService.sendReportEmail(
        report: report,
        email: email,
        visitType: vt,
      );
      WhisperService.debugLog('[SessionNotifier] Report email sent to $email');
    } catch (e) {
      WhisperService.debugLog('[SessionNotifier] Email send failed: $e');
    }
  }

  @override
  void dispose() {
    _preloadTimer?.cancel();
    _reportTimer?.cancel();
    _audioSubscription?.cancel();
    _transcriptSubscription?.cancel();
    _releaseWakeLockAndForeground();
    _whisperService.dispose();
    super.dispose();
  }
}
