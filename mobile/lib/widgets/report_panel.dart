import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/recording_history_provider.dart';
import '../providers/session_provider.dart';

/// Collapsible report panel with close button and fullscreen option.
class ReportPanel extends ConsumerStatefulWidget {
  final VoidCallback? onClose;
  final bool showCloseButton;

  const ReportPanel({super.key, this.onClose, this.showCloseButton = true});

  @override
  ConsumerState<ReportPanel> createState() => _ReportPanelState();
}

class _ReportPanelState extends ConsumerState<ReportPanel> {
  late TextEditingController _controller;
  bool _hasLocalEdits = false;
  bool _isSaving = false;

  /// Tracks the last session report value we synced into the controller.
  /// Used to distinguish external report changes (auto-generate, load)
  /// from local user edits.
  String _lastSyncedReport = '';

  @override
  void initState() {
    super.initState();
    final session = ref.read(sessionProvider);
    _controller = TextEditingController(text: session.report);
    _lastSyncedReport = session.report;
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    final hasEdits = _controller.text != _lastSyncedReport;
    if (hasEdits != _hasLocalEdits) {
      setState(() => _hasLocalEdits = hasEdits);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    final loadedId = ref.watch(loadedRecordingIdProvider);

    // Show snackbar when report generation fails
    ref.listen<SessionState>(sessionProvider, (prev, next) {
      if (prev?.errorMessage == null &&
          next.errorMessage != null &&
          next.report.isEmpty &&
          next.status == RecordingStatus.idle) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Generování zprávy selhalo: ${next.errorMessage}'),
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Zkusit znovu',
              textColor: Colors.white,
              onPressed: () {
                ref.read(sessionProvider.notifier).regenerateReport();
              },
            ),
          ),
        );
      }
    });

    // Sync controller only when the session report changes externally
    // (e.g. auto-generated report, loading a recording).
    // Local user edits must NOT be overwritten.
    if (session.report != _lastSyncedReport) {
      final selection = _controller.selection;
      _controller.text = session.report;
      // Try to restore cursor position if still valid
      if (selection.isValid && selection.end <= _controller.text.length) {
        _controller.selection = selection;
      }
      _lastSyncedReport = session.report;
      _hasLocalEdits = false;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.description, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Lékařská zpráva',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                // Fullscreen button
                IconButton(
                  icon: const Icon(Icons.open_in_full, size: 20),
                  tooltip: 'Zobrazit na celou obrazovku',
                  onPressed: () => _openFullscreen(context, ref),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
                // Copy button
                if (session.report.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.copy, size: 20),
                    tooltip: 'Kopírovat zprávu',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: session.report));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('Zpráva zkopírována'),
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
                // Close / collapse button
                if (widget.showCloseButton && widget.onClose != null)
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Skrýt zprávu',
                    onPressed: widget.onClose,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: _controller,
                maxLines: null,
                expands: true,
                readOnly: false,
                decoration: InputDecoration(
                  hintText:
                      'Začněte nahrávat pro automatické generování lékařské zprávy...',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignLabelWithHint: true,
                ),
                style: theme.textTheme.bodyMedium,
                textAlignVertical: TextAlignVertical.top,
              ),
            ),
            if (session.visitTypeChanged && session.report.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: session.status == RecordingStatus.processing
                        ? null
                        : () => ref
                            .read(sessionProvider.notifier)
                            .regenerateReport(),
                    icon: session.status == RecordingStatus.processing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 18),
                    label: const Text('Přegenerovat zprávu'),
                  ),
                ),
              ),
            // Show regenerate button when report generation failed
            // (error present + transcript exists) or transcript exists
            // but report is empty (timeout / network error on stop).
            if (!session.visitTypeChanged &&
                session.transcript.isNotEmpty &&
                session.report.isEmpty &&
                session.status == RecordingStatus.idle)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    key: const Key('btn_regenerate_report'),
                    onPressed: () {
                      ref.read(sessionProvider.notifier).regenerateReport();
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Vygenerovat zprávu'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            // ── Save changes button for loaded recordings ──
            if (loadedId != null && _hasLocalEdits)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    key: const Key('btn_save_changes'),
                    onPressed: _isSaving ? null : () => _saveChanges(loadedId),
                    icon: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('💾'),
                    label: const Text('Uložit změny'),
                  ),
                ),
              ),
            if (session.report.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Zpráva vygenerována automaticky — zkontrolujte a upravte dle potřeby.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveChanges(String loadedId) async {
    setState(() => _isSaving = true);
    try {
      final storage = ref.read(recordingStorageServiceProvider);
      await storage.updateReport(loadedId, _controller.text);
      await ref.read(recordingIndexProvider.notifier).refresh();
      if (!mounted) return;
      setState(() {
        _lastSyncedReport = _controller.text;
        _hasLocalEdits = false;
        _isSaving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Změny uloženy'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Chyba ukládání: $e')),
      );
    }
  }

  void _openFullscreen(BuildContext context, WidgetRef ref) {
    final session = ref.read(sessionProvider);
    Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenReportView(initialReport: session.report),
      ),
    );
  }
}

/// Fullscreen view for reading / editing the report.
class _FullscreenReportView extends StatefulWidget {
  final String initialReport;
  const _FullscreenReportView({required this.initialReport});

  @override
  State<_FullscreenReportView> createState() => _FullscreenReportViewState();
}

class _FullscreenReportViewState extends State<_FullscreenReportView> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialReport);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description, size: 22),
            SizedBox(width: 8),
            Text('Lékařská zpráva'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Kopírovat',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _controller.text));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Zpráva zkopírována'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: _controller,
          maxLines: null,
          expands: true,
          decoration: InputDecoration(
            hintText: 'Žádná zpráva k zobrazení...',
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            alignLabelWithHint: true,
          ),
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
          textAlignVertical: TextAlignVertical.top,
        ),
      ),
    );
  }
}
