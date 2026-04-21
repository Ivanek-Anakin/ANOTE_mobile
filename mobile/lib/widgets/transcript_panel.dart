import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';

/// Bare scrollable transcript view — no Card, no header.
///
/// Meant to be placed inside a parent container (e.g. the immersive
/// content card in [HomeScreen]).
class TranscriptPanel extends ConsumerWidget {
  const TranscriptPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);

    final isActive = session.status == RecordingStatus.recording;
    final isProcessing = session.status == RecordingStatus.processing;

    final bool waitingForCloud = session.transcript.isEmpty &&
        (isProcessing ||
            (isActive &&
                ref.watch(transcriptionModelProvider) ==
                    TranscriptionModel.cloud));

    if (waitingForCloud) {
      final msg = isActive
          ? 'Nahrávám… Přepis bude k dispozici po zastavení.'
          : 'Přepis se zpracovává v cloudu...';
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                msg,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final String text = session.transcript.isEmpty
        ? (isActive ? 'Čekám na řeč...' : 'Zatím žádný přepis.')
        : session.transcript;

    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: SelectableText(
          text,
          style: theme.textTheme.bodyMedium?.copyWith(
            height: 1.5,
            color: session.transcript.isEmpty
                ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                : null,
          ),
        ),
      ),
    );
  }
}
