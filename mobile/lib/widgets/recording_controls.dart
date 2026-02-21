import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';

class RecordingControls extends ConsumerWidget {
  const RecordingControls({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final notifier = ref.read(sessionProvider.notifier);
    final theme = Theme.of(context);

    final isIdle = session.status == RecordingStatus.idle;
    final isRecording = session.status == RecordingStatus.recording;
    final isProcessing = session.status == RecordingStatus.processing;
    final isDemoPlaying = session.status == RecordingStatus.demoPlaying;

    final canStart = isIdle;
    final canStop = isRecording;
    final canClear = isIdle && (session.transcript.isNotEmpty ||
        session.report.isNotEmpty);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: canStart ? () => notifier.startRecording() : null,
                  icon: const Text('🔴'),
                  label: const Text('Nahrávat'),
                  style: FilledButton.styleFrom(
                    backgroundColor: canStart
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton.icon(
                  onPressed: canStop ? () => notifier.stopRecording() : null,
                  icon: const Text('⬛'),
                  label: const Text('Zastavit'),
                  style: FilledButton.styleFrom(
                    backgroundColor: canStop
                        ? theme.colorScheme.primary
                        : theme.colorScheme.outline,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: canClear ? () => notifier.resetSession() : null,
                  icon: const Text('🗑'),
                  label: const Text('Vymazat vše'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(
                      color: canClear
                          ? theme.colorScheme.error
                          : theme.colorScheme.outline,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (isProcessing || isDemoPlaying)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isProcessing ? 'Dokončování...' : 'Simulace...',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
