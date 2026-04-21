import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/recording_entry.dart';
import '../models/session_state.dart';
import '../providers/recording_history_provider.dart';
import '../providers/session_provider.dart';

/// Collapsible list of saved recordings that replaces the old demo section.
///
/// Reads [recordingIndexProvider] for the lightweight index and
/// [loadedRecordingIdProvider] to highlight the currently loaded entry.
class RecordingHistoryList extends ConsumerStatefulWidget {
  const RecordingHistoryList({super.key});

  @override
  ConsumerState<RecordingHistoryList> createState() =>
      _RecordingHistoryListState();
}

class _RecordingHistoryListState extends ConsumerState<RecordingHistoryList> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final indexAsync = ref.watch(recordingIndexProvider);
    final loadedId = ref.watch(loadedRecordingIdProvider);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Collapsible header ──
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Text('📋', style: TextStyle(fontSize: 20)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Historie nahrávek',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
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

          // ── Body ──
          if (_expanded)
            indexAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (error, _) => Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      'Chyba načítání historie: $error',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(recordingIndexProvider.notifier).refresh(),
                      icon: const Icon(Icons.refresh, size: 16),
                      label: const Text('Zkusit znovu'),
                    ),
                  ],
                ),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Center(
                      child: Text(
                        'Zatím žádné nahrávky.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  );
                }

                return ListView.separated(
                  key: const Key('recording_history_list'),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(left: 8, right: 8, bottom: 12),
                  itemCount: entries.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    final isLoaded = entry.id == loadedId;
                    return _RecordingHistoryItem(
                      key: Key('history_item_${entry.id}'),
                      entry: entry,
                      isLoaded: isLoaded,
                      onTap: () => _onTapEntry(entry),
                      onDelete: () => _onDeleteEntry(entry, isLoaded),
                    );
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  // ── Tap to load ──

  Future<void> _onTapEntry(RecordingIndexEntry indexEntry) async {
    final session = ref.read(sessionProvider);
    final loadedId = ref.read(loadedRecordingIdProvider);

    // If there's unsaved data from a fresh session (not loaded from history),
    // ask for confirmation before overwriting.
    final hasUnsavedData = loadedId == null &&
        (session.transcript.isNotEmpty || session.report.isNotEmpty);

    if (hasUnsavedData) {
      final confirmed = await _showLoadConfirmDialog();
      if (!confirmed) return;
    }

    if (!mounted) return;

    try {
      final storage = ref.read(recordingStorageServiceProvider);
      final fullEntry = await storage.loadEntry(indexEntry.id);
      if (!mounted) return;
      ref.read(sessionProvider.notifier).loadRecording(fullEntry);
      // Close the bottom sheet so the loaded recording is immediately visible.
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Chyba načítání: $e')),
      );
    }
  }

  Future<bool> _showLoadConfirmDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Neuložená data'),
            content: const Text(
              'Máte neuložená data. Chcete je zahodit a načíst vybranou nahrávku?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Zrušit'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Zahodit a načíst'),
              ),
            ],
          ),
        ) ??
        false;
  }

  // ── Delete ──

  Future<void> _onDeleteEntry(RecordingIndexEntry entry, bool isLoaded) async {
    final confirmed = await _showDeleteConfirmDialog();
    if (!confirmed || !mounted) return;

    await ref.read(recordingIndexProvider.notifier).deleteEntry(entry.id);

    if (isLoaded && mounted) {
      ref.read(sessionProvider.notifier).resetSession();
    }
  }

  Future<bool> _showDeleteConfirmDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Smazat nahrávku?'),
            content: const Text(
              'Opravdu chcete smazat tuto nahrávku? Tuto akci nelze vrátit.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Zrušit'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Smazat'),
              ),
            ],
          ),
        ) ??
        false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Individual history item card
// ─────────────────────────────────────────────────────────────────────────────

class _RecordingHistoryItem extends StatelessWidget {
  final RecordingIndexEntry entry;
  final bool isLoaded;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _RecordingHistoryItem({
    super.key,
    required this.entry,
    required this.isLoaded,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: isLoaded ? theme.colorScheme.primaryContainer : null,
      elevation: isLoaded ? 2 : 0.5,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Row 1: date + visit type badge ──
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _formatDate(entry.createdAt),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  _VisitTypeBadge(visitType: entry.visitType),
                ],
              ),
              const SizedBox(height: 4),

              // ── Row 2: transcript preview ──
              if (entry.preview.isNotEmpty)
                Text(
                  '"${entry.preview}"',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontStyle: FontStyle.italic,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 4),

              // ── Row 3: word count · duration + delete icon ──
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _formatMeta(entry.wordCount, entry.durationSeconds),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color:
                            theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      key: Key('delete_${entry.id}'),
                      icon: const Text('🗑️', style: TextStyle(fontSize: 16)),
                      onPressed: onDelete,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                      tooltip: 'Smazat nahrávku',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.day}.${dt.month}.${dt.year} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatMeta(int wordCount, int durationSeconds) {
    final minutes = (durationSeconds / 60).ceil();
    return '$wordCount slov · $minutes min';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Visit type badge
// ─────────────────────────────────────────────────────────────────────────────

class _VisitTypeBadge extends StatelessWidget {
  final String visitType;

  const _VisitTypeBadge({required this.visitType});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vt = VisitTypeApi.fromString(visitType);
    final label = vt.label;
    final color = switch (vt) {
      VisitType.initial => Colors.blue,
      VisitType.followup => Colors.orange,
      VisitType.gastroscopy => Colors.teal,
      VisitType.colonoscopy => Colors.purple,
      VisitType.ultrasound => Colors.indigo,
      VisitType.defaultType => theme.colorScheme.primary,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color, width: 1),
      ),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
