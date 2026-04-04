import 'dart:async';

import 'package:audio_streamer/audio_streamer.dart';
import 'package:permission_handler/permission_handler.dart';

/// Thrown when microphone permission is denied by the user.
class MicPermissionDenied implements Exception {
  final String message;

  const MicPermissionDenied(
      [this.message = 'Microphone permission denied']);

  @override
  String toString() => 'MicPermissionDenied: $message';
}

/// Captures raw PCM audio samples from the device microphone.
///
/// Provides a [Stream<List<double>>] of audio samples at 16 kHz mono.
class AudioService {
  StreamSubscription<List<double>>? _subscription;
  final StreamController<List<double>> _controller =
      StreamController<List<double>>.broadcast();

  /// Stream of incoming audio sample buffers (float32, 16 kHz, mono).
  Stream<List<double>> get audioStream => _controller.stream;

  /// Request microphone permission and start streaming audio samples.
  ///
  /// Throws [MicPermissionDenied] if the user denies the permission.
  Future<void> start() async {
    final PermissionStatus status = await Permission.microphone.request();
    if (!status.isGranted) {
      throw const MicPermissionDenied();
    }

    // Configure sample rate before subscribing to the stream.
    AudioStreamer().sampleRate = 16000;

    _subscription = AudioStreamer().audioStream.listen(
      (List<double> buffer) => _controller.add(buffer),
      onError: (Object error) => _controller.addError(error),
      cancelOnError: false,
    );
  }

  /// Stop audio capture and cancel the stream subscription.
  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Release all resources.
  void dispose() {
    _subscription?.cancel();
    if (!_controller.isClosed) {
      _controller.close();
    }
  }
}
