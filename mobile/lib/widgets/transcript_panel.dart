import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';

class TranscriptPanel extends ConsumerStatefulWidget {
  const TranscriptPanel({super.key});

  @override
  ConsumerState<TranscriptPanel> createState() => _TranscriptPanelState();
}

class _TranscriptPanelState extends ConsumerState<TranscriptPanel> {
  bool _expanded = true;

  @override
  Widget build(
    BuildContext context,
  ) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);

    final isActive = session.status == RecordingStatus.recording;
    final hasContent = session.transcript.isNotEmpty;

    if (!isActive && !hasContent) {
      return const SizedBox.shrink();
    }

    final statusLabel = isActive ? 'Probíhá...' : 'Dokončeno';
    final statusColor =
        isActive ? theme.colorScheme.error : Colors.green.shade600;

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('🎤', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      'Přepis řeči',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: statusColor, width: 1),
                    ),
                    child: Text(
                      statusLabel,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: statusColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Fullscreen button
                  IconButton(
                    icon: const Icon(Icons.open_in_full, size: 20),
                    tooltip: 'Zobrazit na celou obrazovku',
                    onPressed: () =>
                        _openFullscreen(context, session.transcript),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                  // Copy button
                  if (hasContent)
                    IconButton(
                      icon: const Icon(Icons.copy, size: 20),
                      tooltip: 'Kopírovat přepis',
                      onPressed: () {
                        Clipboard.setData(
                            ClipboardData(text: session.transcript));
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Přepis zkopírován'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                    ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 200),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    session.transcript.isEmpty
                        ? 'Čekám na řeč...'
                        : session.transcript,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: session.transcript.isEmpty
                          ? theme.colorScheme.onSurface.withValues(alpha: 0.5)
                          : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context, String transcript) {
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenTranscriptView(transcript: transcript),
      ),
    );
  }
}

/// Fullscreen view for reading / copying the transcript.
class _FullscreenTranscriptView extends StatelessWidget {
  final String transcript;
  const _FullscreenTranscriptView({required this.transcript});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎤 Přepis řeči'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Kopírovat',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: transcript));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Přepis zkopírován'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: SelectableText(
            transcript.isEmpty ? 'Žádný přepis k zobrazení...' : transcript,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          ),
        ),
      ),
    );
  }
}
