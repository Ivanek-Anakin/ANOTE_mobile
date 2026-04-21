import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/recording_history_provider.dart';
import '../providers/session_provider.dart';

/// Bare editable report view — no Card, no header.
///
/// Keeps a [TextEditingController] synced with [sessionProvider] and
/// notifies the parent when the user locally edits the auto-generated
/// report via [onEditStateChanged].
class ReportPanel extends ConsumerStatefulWidget {
  /// Called whenever the "has local user edits" flag changes.
  /// Parents use this to toggle the action row button between
  /// "Přepis" and "Odeslat emailem".
  final ValueChanged<bool>? onEditStateChanged;

  const ReportPanel({super.key, this.onEditStateChanged});

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
      widget.onEditStateChanged?.call(hasEdits);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    final loadedId = ref.watch(loadedRecordingIdProvider);

    // Show snackbar when report generation fails.
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
      if (selection.isValid && selection.end <= _controller.text.length) {
        _controller.selection = selection;
      }
      _lastSyncedReport = session.report;
      if (_hasLocalEdits) {
        _hasLocalEdits = false;
        widget.onEditStateChanged?.call(false);
      }
    }

    final isGenerating =
        session.status == RecordingStatus.processing && session.report.isEmpty;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: isGenerating
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(
                          width: 32,
                          height: 32,
                          child: CircularProgressIndicator(strokeWidth: 3),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Generuji lékařskou zprávu…',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  )
                : TextField(
                    controller: _controller,
                    maxLines: null,
                    expands: true,
                    decoration: const InputDecoration(
                      hintText:
                          'Začněte nahrávat pro automatické generování lékařské zprávy...',
                      border: InputBorder.none,
                      isCollapsed: true,
                    ),
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
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
                      : () =>
                          ref.read(sessionProvider.notifier).regenerateReport(),
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
                      : const Icon(Icons.save_outlined, size: 18),
                  label: const Text('Uložit změny'),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _saveChanges(String loadedId) async {
    FocusScope.of(context).unfocus();
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
      widget.onEditStateChanged?.call(false);
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
}
