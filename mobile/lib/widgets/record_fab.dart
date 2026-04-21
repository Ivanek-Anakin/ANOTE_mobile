import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/constants.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';

/// 72px circular record button with a pulse animation while recording.
///
/// * Idle  → green [AppColors.anoteGreen], mic icon, tap starts recording.
/// * Recording → red [AppColors.recordingRed], stop icon, pulsing glow,
///   tap stops recording.
/// * Processing → disabled with a spinner overlay.
class RecordFAB extends ConsumerStatefulWidget {
  /// Optional override invoked on tap while idle. When null the button
  /// calls [SessionNotifier.startRecording] directly.
  final VoidCallback? onIdleTap;

  const RecordFAB({super.key, this.onIdleTap});

  @override
  ConsumerState<RecordFAB> createState() => _RecordFABState();
}

class _RecordFABState extends ConsumerState<RecordFAB>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  void _syncAnimation(RecordingStatus status) {
    if (status == RecordingStatus.recording) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      if (_pulse.isAnimating) _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final notifier = ref.read(sessionProvider.notifier);

    final isIdle = session.status == RecordingStatus.idle;
    final isRecording = session.status == RecordingStatus.recording;
    final isProcessing = session.status == RecordingStatus.processing;

    _syncAnimation(session.status);

    final Color color = isRecording
        ? AppColors.recordingRed
        : (isProcessing
            ? AppColors.anoteGreen.withValues(alpha: 0.5)
            : AppColors.anoteGreen);
    final IconData icon = isRecording ? Icons.stop : Icons.mic;

    VoidCallback? onTap;
    if (isIdle) {
      onTap = widget.onIdleTap ?? () => notifier.startRecording();
    } else if (isRecording) {
      onTap = () => notifier.stopRecording();
    }

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        final double t = _pulse.value;
        final double glow = isRecording ? (18 + 14 * (1 - t)) : 12;
        final double alpha = isRecording ? (0.45 * (1 - t) + 0.15) : 0.25;
        return GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: alpha),
                  blurRadius: glow,
                  spreadRadius: isRecording ? 4 * (1 - t) : 0,
                ),
              ],
            ),
            child: isProcessing
                ? const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    ),
                  )
                : Icon(icon, color: Colors.white, size: 34),
          ),
        );
      },
    );
  }
}
