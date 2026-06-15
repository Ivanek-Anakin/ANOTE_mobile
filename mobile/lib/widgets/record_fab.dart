import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/constants.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';

/// ANOTE logo-style record button.
///
/// Outer circle: green (idle/processing) or red (recording).
/// Inner white circle: always pulses opacity 1.0 → 0.4 over 1 500 ms.
/// Outer circle: subtly grows (scale 1.0 → 1.06) while recording.
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
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _opacity = Tween<double>(begin: 1.0, end: 0.4).animate(
      CurvedAnimation(parent: _pulse, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final notifier = ref.read(sessionProvider.notifier);

    final isIdle = session.status == RecordingStatus.idle;
    final isRecording = session.status == RecordingStatus.recording;
    final isProcessing = session.status == RecordingStatus.processing;

    final Color outerColor = isRecording
        ? AppColors.recordingRed
        : (isProcessing
            ? AppColors.anoteGreen.withValues(alpha: 0.5)
            : AppColors.anoteGreen);

    VoidCallback? onTap;
    if (isIdle) {
      onTap = widget.onIdleTap ?? () => notifier.startRecording();
    } else if (isRecording) {
      onTap = () => notifier.stopRecording();
    }

    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, _) {
        // Outer circle subtly grows while recording.
        final double scale = isRecording ? (1.0 + 0.06 * _pulse.value) : 1.0;

        return GestureDetector(
          onTap: onTap,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: outerColor,
                shape: BoxShape.circle,
              ),
              child: isProcessing
                  ? const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 3,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                    )
                  : Center(
                      child: Opacity(
                        opacity: _opacity.value,
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: const BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
        );
      },
    );
  }
}
