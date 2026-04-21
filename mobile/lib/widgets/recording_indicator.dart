import 'package:flutter/material.dart';

import '../config/constants.dart';

/// "● Nahrávání..." pill shown above the record FAB while recording.
///
/// Red dot blinks (opacity 1.0 ↔ 0.3) on a ~1s cycle.
class RecordingIndicator extends StatefulWidget {
  const RecordingIndicator({super.key});

  @override
  State<RecordingIndicator> createState() => _RecordingIndicatorState();
}

class _RecordingIndicatorState extends State<RecordingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _blink;
  late final Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _opacity = Tween<double>(begin: 1.0, end: 0.3).animate(_blink);
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FadeTransition(
          opacity: _opacity,
          child: Container(
            width: 10,
            height: 10,
            decoration: const BoxDecoration(
              color: AppColors.recordingRed,
              shape: BoxShape.circle,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          'Nahrávání...',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: AppColors.recordingRed,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
