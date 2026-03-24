import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'whisper_service.dart' show WhisperService;

/// Entry point for the persistent Whisper worker isolate (Phase 3).
///
/// Owns all sherpa_onnx FFI resources ([sherpa.OfflineRecognizer],
/// [sherpa.VoiceActivityDetector]) and audio buffers. Processes messages
/// sequentially from the main isolate via [ReceivePort].
///
/// ## Message protocol (Main → Worker)
///
/// All messages are `Map<String, dynamic>`:
///
/// | `cmd`            | Additional keys                                           |
/// |------------------|-----------------------------------------------------------|
/// | `init`           | `encoderPath`, `decoderPath`, `tokensPath`, `vadModelPath`|
/// | `feedAudio`      | `samples` (`TransferableTypedData`)                       |
/// | `transcribeFull` | —                                                         |
/// | `transcribeTail` | —                                                         |
/// | `reset`          | —                                                         |
/// | `dispose`        | —                                                         |
///
/// ## Message protocol (Worker → Main)
///
/// First message: the worker's [SendPort].
/// Subsequent messages are `Map<String, dynamic>`:
///
/// | `type`                 | Additional keys          |
/// |------------------------|--------------------------|
/// | `initDone`             | —                        |
/// | `initError`            | `error` (String)         |
/// | `transcript`           | `text` (String)          |
/// | `transcribeFullDone`   | `text` (String)          |
/// | `transcribeFullError`  | `error` (String)         |
/// | `transcribeTailDone`   | `text` (String)          |
/// | `transcribeTailError`  | `error` (String)         |
/// | `finalChunkDone`       | `chunkIndex` (int)       |
/// | `resetDone`            | —                        |
/// | `disposeDone`          | —                        |
void whisperWorkerEntryPoint(SendPort mainSendPort) {
  final workerReceivePort = ReceivePort();
  mainSendPort.send(workerReceivePort.sendPort);

  // ---------------------------------------------------------------------------
  // Worker-owned state — ALL buffer management lives here
  // ---------------------------------------------------------------------------
  sherpa.OfflineRecognizer? recognizer;
  sherpa.VoiceActivityDetector? vad;
  String vadModelPath = '';
  String hotwordsFilePath = '';

  /// Raw audio buffer — capped at [maxBufferSamples] to prevent OOM.
  /// Oldest samples are discarded when the cap is reached.
  final List<double> rawAudioBuffer = [];

  /// VAD-filtered speech buffer — capped at [maxSpeechBufferSamples].
  final List<double> speechBuffer = [];

  int lastSpeechBoundary = 0;
  String previousTailText = '';
  String fullTranscript = '';
  bool isTranscribing = false;

  // Phase 4: Incremental final-quality chunk state
  /// Start index in speechBuffer for the next incremental final chunk.
  int finalizedBoundary = 0;

  /// Transcription results from completed incremental chunks.
  final List<String> finalizedChunks = [];

  /// Tail text of the last finalized chunk (for overlap deduplication).
  String previousChunkTail = '';

  const int sampleRate = 16000;
  const int windowInterval = 5 * sampleRate; // 5 s (matches Phase 1)
  const int overlapSamples = 3 * sampleRate; // 3 s

  /// Maximum raw audio buffer: 30 minutes @ 16 kHz = 28,800,000 samples.
  /// At 8 bytes/double this is ~230 MB — the hard ceiling.
  const int maxBufferSamples = 30 * 60 * sampleRate; // 30 min

  /// Maximum speech buffer: 20 minutes of speech (generous — VAD filters
  /// silence so real speech is typically <60% of recording time).
  const int maxSpeechBufferSamples = 20 * 60 * sampleRate; // 20 min

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  void workerLog(String message) {
    // ignore: avoid_print
    print(message);
  }

  /// Decode a single chunk of samples using the persistent recognizer.
  String transcribe(List<double> samples) {
    final stream = recognizer!.createStream();
    stream.acceptWaveform(
      samples: Float32List.fromList(samples),
      sampleRate: sampleRate,
    );
    final sw = Stopwatch()..start();
    recognizer!.decode(stream);
    sw.stop();
    workerLog('[PERF][Worker] decode() took ${sw.elapsedMilliseconds}ms '
        'for ${samples.length} samples');
    final result = recognizer!.getResult(stream);
    stream.free();
    return result.text.trim();
  }

  /// Sliding-window live transcription — called when enough speech accumulates.
  void transcribeWindow() {
    if (isTranscribing) return;
    if (speechBuffer.length - lastSpeechBoundary < windowInterval) return;
    isTranscribing = true;

    try {
      final int overlapStart = max(0, lastSpeechBoundary - overlapSamples);
      final int windowEnd = speechBuffer.length;
      final List<double> window =
          List<double>.from(speechBuffer.sublist(overlapStart, windowEnd));

      final String rawText = transcribe(window);
      if (rawText.isEmpty) {
        lastSpeechBoundary = windowEnd;
        return;
      }

      final String deduped =
          WhisperService.removeOverlap(previousTailText, rawText);
      if (deduped.isNotEmpty) {
        fullTranscript =
            fullTranscript.isEmpty ? deduped : '$fullTranscript $deduped';
      }

      previousTailText = WhisperService.lastWords(rawText, 20);
      lastSpeechBoundary = windowEnd;

      // Send transcript update to main isolate
      mainSendPort.send({'type': 'transcript', 'text': fullTranscript});
    } catch (e) {
      workerLog('[Worker] transcribeWindow error: $e');
    } finally {
      isTranscribing = false;
    }
  }

  /// Extract speech segments from raw audio using a **fresh** VAD instance
  /// (lower threshold for the final pass).
  List<Float32List> extractSpeechSegments(List<double> rawAudio) {
    if (vadModelPath.isEmpty) {
      return [Float32List.fromList(rawAudio)];
    }

    final List<Float32List> segments = [];
    try {
      final extractVad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: vadModelPath,
            threshold:
                0.45, // slightly lower for final pass — catch more speech
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
        extractVad.acceptWaveform(padded);

        while (!extractVad.isEmpty()) {
          final segment = extractVad.front();
          extractVad.pop();
          if (segment.samples.isNotEmpty) {
            segments.add(segment.samples);
          }
        }
      }

      // Flush remaining speech
      extractVad.flush();
      while (!extractVad.isEmpty()) {
        final segment = extractVad.front();
        extractVad.pop();
        if (segment.samples.isNotEmpty) {
          segments.add(segment.samples);
        }
      }

      extractVad.free();
    } catch (e) {
      workerLog('[Worker] VAD extraction failed: $e — using raw audio.');
      return [Float32List.fromList(rawAudio)];
    }

    return segments;
  }

  /// High-quality full-pass transcription over all recorded audio.
  ///
  /// Re-runs VAD at 0.45 threshold on the raw audio buffer to catch quiet
  /// speech that the live VAD (0.5) may have missed. Falls back to
  /// speechBuffer if rawAudioBuffer is empty.
  String doTranscribeFull() {
    final List<double> allSpeech;
    if (rawAudioBuffer.isNotEmpty) {
      // Re-extract speech from raw audio at lower threshold (0.45)
      final segments = extractSpeechSegments(rawAudioBuffer);
      if (segments.isEmpty) {
        workerLog('[Worker] transcribeFull: re-VAD returned no segments, '
            'falling back to speechBuffer');
        if (speechBuffer.isNotEmpty) {
          allSpeech = speechBuffer;
        } else {
          return '';
        }
      } else {
        final extracted = <double>[];
        for (final seg in segments) {
          extracted.addAll(seg);
        }
        allSpeech = extracted;
        workerLog('[Worker] transcribeFull: re-VAD extracted '
            '${allSpeech.length} samples '
            '(${(allSpeech.length / sampleRate).toStringAsFixed(1)}s of speech) '
            'from ${rawAudioBuffer.length} raw samples');
      }
    } else if (speechBuffer.isNotEmpty) {
      allSpeech = speechBuffer;
      workerLog('[Worker] transcribeFull: rawAudioBuffer empty, '
          'using speechBuffer — '
          '${allSpeech.length} samples '
          '(${(allSpeech.length / sampleRate).toStringAsFixed(1)}s of speech)');
    } else {
      return '';
    }

    // Short speech (< 30 s) — transcribe in one shot
    const int maxSinglePass = 30 * sampleRate;
    if (allSpeech.length <= maxSinglePass) {
      final result = transcribe(allSpeech);
      workerLog('[Worker] transcribeFull done: ${result.length} chars');
      return result;
    }

    // Longer speech — 30 s chunks with 5 s overlap
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
      } catch (e) {
        workerLog('[Worker] transcribeFull chunk error: $e');
      }
    }

    final result = parts.join(' ');
    workerLog('[Worker] transcribeFull done: ${result.length} chars');
    return result;
  }

  /// Phase 4: Transcribe only the un-finalized tail of the speech buffer,
  /// then concatenate with already-finalized chunks.
  ///
  /// This is the fast path called after the user stops recording. Only the
  /// remaining tail (typically < 30s) needs decoding — all earlier chunks
  /// were already transcribed incrementally during recording.
  String doTranscribeTail() {
    const int chunkSize = 30 * sampleRate;
    const int overlap = 5 * sampleRate;

    String tailText = '';
    if (finalizedBoundary < speechBuffer.length) {
      final tail = speechBuffer.sublist(finalizedBoundary);
      workerLog('[Worker] transcribeTail: ${tail.length} samples '
          '(${(tail.length / sampleRate).toStringAsFixed(1)}s) remaining, '
          '${finalizedChunks.length} finalized chunks');

      if (tail.length <= chunkSize) {
        final text = transcribe(tail);
        tailText = WhisperService.removeOverlap(previousChunkTail, text);
      } else {
        // Tail longer than one chunk — split into sub-chunks
        final parts = <String>[];
        String prevTail = previousChunkTail;
        for (int start = 0;
            start < tail.length;
            start += chunkSize - overlap) {
          final int end = min(start + chunkSize, tail.length);
          final chunk = tail.sublist(start, end);
          try {
            final text = transcribe(chunk);
            if (text.isEmpty) continue;
            final deduped = WhisperService.removeOverlap(prevTail, text);
            if (deduped.isNotEmpty) parts.add(deduped);
            prevTail = WhisperService.lastWords(text, 20);
          } catch (e) {
            workerLog('[Worker] transcribeTail chunk error: $e');
          }
        }
        tailText = parts.join(' ');
      }
    } else {
      workerLog('[Worker] transcribeTail: no tail samples, '
          '${finalizedChunks.length} finalized chunks');
    }

    final allParts = [...finalizedChunks];
    if (tailText.isNotEmpty) allParts.add(tailText);
    final result = allParts.join(' ');
    workerLog('[Worker] transcribeTail done: '
        '${finalizedChunks.length} chunks + tail = ${result.length} chars');
    return result;
  }

  // ---------------------------------------------------------------------------
  // Message loop
  // ---------------------------------------------------------------------------
  workerReceivePort.listen((dynamic message) {
    if (message is! Map) return;
    final cmd = message['cmd'] as String?;

    switch (cmd) {
      case 'init':
        try {
          final encoderPath = message['encoderPath'] as String;
          final decoderPath = message['decoderPath'] as String;
          final tokensPath = message['tokensPath'] as String;
          vadModelPath = message['vadModelPath'] as String;
          hotwordsFilePath = (message['hotwordsFilePath'] as String?) ?? '';

          sherpa.initBindings();

          final sw = Stopwatch()..start();
          recognizer = sherpa.OfflineRecognizer(
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
              decodingMethod: 'modified_beam_search',
              maxActivePaths: 4,
              hotwordsFile: hotwordsFilePath,
              hotwordsScore: 1.5,
            ),
          );
          sw.stop();
          workerLog('[PERF][Worker] Recognizer creation took '
              '${sw.elapsedMilliseconds}ms');

          try {
            vad = sherpa.VoiceActivityDetector(
              config: sherpa.VadModelConfig(
                sileroVad: sherpa.SileroVadModelConfig(
                  model: vadModelPath,
                  threshold: 0.5,
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
            workerLog('[Worker] Silero VAD initialized.');
          } catch (e) {
            workerLog('[Worker] VAD init failed: $e — continuing without VAD.');
            vad = null;
          }

          mainSendPort.send({'type': 'initDone'});
        } catch (e) {
          mainSendPort.send({'type': 'initError', 'error': e.toString()});
        }

      case 'feedAudio':
        try {
          final TransferableTypedData transferable =
              message['samples'] as TransferableTypedData;
          final ByteBuffer buffer = transferable.materialize();
          final Float32List samples = buffer.asFloat32List();

          // Append raw audio directly from Float32List — no .toList() copy.
          // Float32List implements List<double> so addAll works directly.
          rawAudioBuffer.addAll(samples);

          // Cap raw buffer: discard oldest samples beyond 30 min.
          if (rawAudioBuffer.length > maxBufferSamples) {
            final excess = rawAudioBuffer.length - maxBufferSamples;
            rawAudioBuffer.removeRange(0, excess);
            workerLog('[Worker] rawAudioBuffer capped: removed $excess '
                'oldest samples (now ${rawAudioBuffer.length})');
          }

          if (vad == null) {
            speechBuffer.addAll(samples);
          } else {
            final vadSw = Stopwatch()..start();
            vad!.acceptWaveform(samples);
            vadSw.stop();
            if (vadSw.elapsedMilliseconds > 5) {
              workerLog('[PERF][Worker] acceptWaveform() took '
                  '${vadSw.elapsedMilliseconds}ms '
                  'for ${samples.length} samples');
            }

            while (!vad!.isEmpty()) {
              final segment = vad!.front();
              vad!.pop();
              if (segment.samples.isNotEmpty) {
                // Append directly — segment.samples is already Float32List.
                speechBuffer.addAll(segment.samples);
                workerLog('[Worker] VAD speech segment: '
                    '${segment.samples.length} samples '
                    '(${(segment.samples.length / sampleRate).toStringAsFixed(2)}s)');
              }
            }
          }

          // Cap speech buffer: discard oldest beyond 20 min of speech.
          if (speechBuffer.length > maxSpeechBufferSamples) {
            final excess = speechBuffer.length - maxSpeechBufferSamples;
            speechBuffer.removeRange(0, excess);
            // Adjust boundaries to account for removed samples.
            lastSpeechBoundary = max(0, lastSpeechBoundary - excess);
            finalizedBoundary = max(0, finalizedBoundary - excess);
            workerLog('[Worker] speechBuffer capped: removed $excess '
                'oldest samples (now ${speechBuffer.length})');
          }

          // Trigger live transcription when enough speech has accumulated
          if (!isTranscribing &&
              speechBuffer.length - lastSpeechBoundary >= windowInterval) {
            transcribeWindow();
          }

          // Phase 4: Incremental final-quality chunk during recording.
          // Only attempt when not already transcribing (live window has
          // priority) and enough new speech has accumulated.
          const int finalChunkSize = 30 * sampleRate;
          const int finalOverlap = 5 * sampleRate;
          if (!isTranscribing &&
              speechBuffer.length - finalizedBoundary >= finalChunkSize) {
            isTranscribing = true;
            try {
              final chunk = speechBuffer.sublist(
                  finalizedBoundary, finalizedBoundary + finalChunkSize);
              final text = transcribe(chunk);
              if (text.isNotEmpty) {
                final deduped =
                    WhisperService.removeOverlap(previousChunkTail, text);
                if (deduped.isNotEmpty) {
                  finalizedChunks.add(deduped);
                }
                previousChunkTail = WhisperService.lastWords(text, 20);
              }
              finalizedBoundary += finalChunkSize - finalOverlap;
              workerLog('[Worker] Finalized chunk ${finalizedChunks.length}: '
                  'boundary now at '
                  '${(finalizedBoundary / sampleRate).toStringAsFixed(1)}s');
              mainSendPort.send({
                'type': 'finalChunkDone',
                'chunkIndex': finalizedChunks.length,
              });
            } catch (e) {
              workerLog('[Worker] finalChunk error: $e');
            } finally {
              isTranscribing = false;
            }
          }
        } catch (e) {
          workerLog('[Worker] feedAudio error: $e');
        }

      case 'transcribeFull':
        try {
          final result = doTranscribeFull();
          mainSendPort.send({'type': 'transcribeFullDone', 'text': result});
        } catch (e) {
          mainSendPort
              .send({'type': 'transcribeFullError', 'error': e.toString()});
        }

      case 'transcribeTail':
        try {
          final result = doTranscribeTail();
          mainSendPort.send({'type': 'transcribeTailDone', 'text': result});
        } catch (e) {
          mainSendPort
              .send({'type': 'transcribeTailError', 'error': e.toString()});
        }

      case 'reset':
        speechBuffer.clear();
        rawAudioBuffer.clear();
        lastSpeechBoundary = 0;
        previousTailText = '';
        fullTranscript = '';
        isTranscribing = false;
        finalizedBoundary = 0;
        finalizedChunks.clear();
        previousChunkTail = '';
        vad?.reset();
        mainSendPort.send({'type': 'resetDone'});

      case 'dispose':
        recognizer?.free();
        recognizer = null;
        vad?.free();
        vad = null;
        speechBuffer.clear();
        rawAudioBuffer.clear();
        finalizedChunks.clear();
        mainSendPort.send({'type': 'disposeDone'});
        workerReceivePort.close();
    }
  });
}
