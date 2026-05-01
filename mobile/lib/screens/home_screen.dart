import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/constants.dart';
import '../models/session_state.dart';
import '../providers/recording_history_provider.dart';
import '../providers/session_provider.dart';
import '../widgets/record_fab.dart';
import '../widgets/recording_history_list.dart';
import '../widgets/recording_indicator.dart';
import '../widgets/report_panel.dart';
import '../widgets/transcript_panel.dart';

bool _isWarningMessage(String? message) {
  if (message == null) return false;
  return message.contains('vypnuté kvůli limitu paměti') ||
      message.contains('vejde bezpečně do paměti');
}

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  /// When true, the content card shows the transcript; otherwise the report.
  bool _showTranscript = false;

  /// When true, the user has locally edited the report. The left action
  /// button becomes "Odeslat emailem" and the card is locked to report view.
  bool _reportHasEdits = false;

  Timer? _warningTimer;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      ref.read(sessionProvider.notifier).preloadModel();
    });
  }

  @override
  void dispose() {
    _warningTimer?.cancel();
    super.dispose();
  }

  // ───────────────────────── actions ─────────────────────────

  Future<void> _sendEmail() async {
    final session = ref.read(sessionProvider);
    final email = ref.read(emailReportAddressProvider);
    final messenger = ScaffoldMessenger.of(context);

    if (session.report.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text('Žádná zpráva k odeslání.'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    if (email.isEmpty) {
      messenger.showSnackBar(SnackBar(
        content: const Text('Nastavte emailovou adresu v Nastavení.'),
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: 'Nastavení',
          onPressed: () => Navigator.pushNamed(context, '/settings'),
        ),
      ));
      return;
    }
    messenger.showSnackBar(SnackBar(
      content: Text('Odesílám zprávu na $email…'),
      duration: const Duration(seconds: 2),
    ));
    try {
      await ref
          .read(sessionProvider.notifier)
          .sendReportEmailNow(report: session.report);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
        content: Text('Zpráva odeslána.'),
        duration: Duration(seconds: 2),
        backgroundColor: AppColors.anoteGreen,
      ));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Odeslání selhalo: $e'),
        backgroundColor: Theme.of(context).colorScheme.error,
      ));
    }
  }

  void _copyVisibleContent() {
    final session = ref.read(sessionProvider);
    final text = _showTranscript ? session.transcript : session.report;
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content:
          Text(_showTranscript ? 'Přepis zkopírován' : 'Zpráva zkopírována'),
      duration: const Duration(seconds: 2),
    ));
  }

  void _openHistorySheet() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: const RecordingHistoryList(),
            );
          },
        );
      },
    );
  }

  /// Save current session to history (if any) and clear the screen.
  /// When [thenStartRecording] is true, immediately starts a new recording
  /// after the save+clear completes via the canonical [restartRecording]
  /// path so Journey B (post-stop "Start") matches Journey A ("+" → mic).
  Future<void> _saveAndClear({required bool thenStartRecording}) async {
    FocusScope.of(context).unfocus();
    final notifier = ref.read(sessionProvider.notifier);
    final session = ref.read(sessionProvider);
    final hadContent =
        session.transcript.isNotEmpty || session.report.isNotEmpty;

    if (thenStartRecording) {
      // Single canonical path: save existing → resetSession → startRecording.
      await notifier.restartRecording();
    } else {
      await notifier.startNewRecording(); // saves + resets session
    }
    if (!mounted) return;
    setState(() {
      _reportHasEdits = false;
      _showTranscript = false;
    });
    if (!thenStartRecording && hadContent) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Nahrávka uložena'),
        duration: Duration(seconds: 2),
      ));
    }
  }

  void _onRecordFabIdleTap() {
    final session = ref.read(sessionProvider);
    final hasContent =
        session.transcript.isNotEmpty || session.report.isNotEmpty;
    if (hasContent) {
      _saveAndClear(thenStartRecording: true);
    } else {
      ref.read(sessionProvider.notifier).startRecording();
    }
  }

  // ───────────────────────── build ─────────────────────────

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final isWide = width > 900;
    final isWarning = _isWarningMessage(session.errorMessage);
    final loadedFromHistory = ref.watch(loadedRecordingIdProvider) != null;

    // Offline fallback snackbar + warning auto-hide.
    ref.listen<SessionState>(sessionProvider, (prev, next) {
      if (prev != null &&
          prev.status != RecordingStatus.recording &&
          next.status == RecordingStatus.recording) {
        final messenger = ScaffoldMessenger.of(context);
        Future.delayed(const Duration(seconds: 4), () {
          if (!mounted) return;
          final fallback =
              ref.read(sessionProvider.notifier).consumeOfflineFallback();
          if (fallback != null) {
            messenger.showSnackBar(SnackBar(
              content: Text(
                'Bez internetu — přepis přepnut na ${fallback == TranscriptionModel.turbo ? "Turbo" : "Small"} (offline)',
              ),
              duration: const Duration(seconds: 4),
              backgroundColor: Colors.orange.shade700,
            ));
          }
        });
      }

      final nextIsWarning = _isWarningMessage(next.errorMessage);
      if (nextIsWarning && next.errorMessage != prev?.errorMessage) {
        final warningText = next.errorMessage;
        _warningTimer?.cancel();
        _warningTimer = Timer(const Duration(seconds: 10), () {
          if (!mounted) return;
          final currentMessage = ref.read(sessionProvider).errorMessage;
          if (currentMessage == warningText) {
            ref.read(sessionProvider.notifier).clearErrorMessage();
          }
        });
      } else if (!nextIsWarning && next.errorMessage != prev?.errorMessage) {
        _warningTimer?.cancel();
      }

      // When a new report arrives from auto-generation, reset to report view.
      if (prev?.report != next.report && next.report.isNotEmpty) {
        if (mounted && _showTranscript) {
          setState(() => _showTranscript = false);
        }
      }

      // When recording transitions stop→idle, always drop back to report view
      // so the next session starts fresh with the correct panel visible.
      if (prev?.status == RecordingStatus.recording &&
          next.status != RecordingStatus.recording) {
        if (mounted && _showTranscript) {
          setState(() => _showTranscript = false);
        }
      }
    });

    // When a recording is loaded from history, force report view + clear edits.
    ref.listen<String?>(loadedRecordingIdProvider, (prev, next) {
      if (next != null && next != prev && mounted) {
        setState(() {
          _showTranscript = false;
          _reportHasEdits = false;
        });
      }
    });

    // Show the transcript automatically while recording.
    final effectiveShowTranscript = _reportHasEdits
        ? false
        : (session.status == RecordingStatus.recording || _showTranscript);

    return Scaffold(
      appBar: AppBar(
        title: const Text('ANOTE'),
        actions: [
          IconButton(
            key: const Key('btn_history'),
            icon: const Icon(Icons.history),
            tooltip: 'Historie nahrávek',
            onPressed: _openHistorySheet,
          ),
          IconButton(
            key: const Key('btn_settings'),
            icon: const Icon(Icons.settings),
            tooltip: 'Nastavení',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            if (session.modelDownloadProgress != null)
              _buildDownloadBanner(theme, session),
            if (session.errorMessage != null)
              _buildErrorBanner(theme, session, isWarning),
            Expanded(
              child: isWide
                  ? _buildWideLayout(theme, session, effectiveShowTranscript,
                      loadedFromHistory)
                  : _buildNarrowLayout(theme, session, effectiveShowTranscript,
                      loadedFromHistory),
            ),
          ],
        ),
      ),
    );
  }

  // ───────────────────────── banners ─────────────────────────

  Widget _buildDownloadBanner(ThemeData theme, SessionState session) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Stahování modelu${session.modelDownloadFileName != null ? ': ${session.modelDownloadFileName}' : ''}',
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${(session.modelDownloadProgress! * 100).toInt()}%',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: session.modelDownloadProgress,
              minHeight: 6,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(
      ThemeData theme, SessionState session, bool isWarning) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              session.errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isWarning
                    ? Colors.orange.shade700
                    : theme.colorScheme.error,
              ),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!session.isModelLoaded)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                height: 28,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(sessionProvider.notifier).retryModelLoad(),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Zkusit znovu'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                ),
              ),
            ),
          if (session.isModelLoaded &&
              session.transcript.isNotEmpty &&
              session.status == RecordingStatus.idle)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                height: 28,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      ref.read(sessionProvider.notifier).regenerateReport(),
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Zkusit znovu'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    textStyle: theme.textTheme.bodySmall
                        ?.copyWith(fontWeight: FontWeight.w600),
                    foregroundColor: theme.colorScheme.error,
                    side: BorderSide(color: theme.colorScheme.error),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ───────────────────────── layouts ─────────────────────────

  Widget _buildNarrowLayout(
    ThemeData theme,
    SessionState session,
    bool showTranscript,
    bool loadedFromHistory,
  ) {
    final isRecording = session.status == RecordingStatus.recording;
    final hasReport = session.report.isNotEmpty;
    final hasTranscript = session.transcript.isNotEmpty;
    final hasAnyContent = hasReport || hasTranscript || isRecording;

    // "Send email" mode: user edited report OR loaded from history
    // (treated as already reviewed, per spec).
    final emailMode = _reportHasEdits || (loadedFromHistory && hasReport);

    return Column(
      children: [
        const SizedBox(height: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _ContentCard(
              showTranscript: showTranscript,
              onReportEditStateChanged: (hasEdits) {
                if (!mounted) return;
                if (hasEdits != _reportHasEdits) {
                  setState(() => _reportHasEdits = hasEdits);
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 8),
        if (hasAnyContent)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _ActionRow(
              emailMode: emailMode,
              showingTranscript: showTranscript,
              hasReport: hasReport,
              hasTranscript: hasTranscript,
              onToggleView: () {
                setState(() => _showTranscript = !_showTranscript);
              },
              onSendEmail: _sendEmail,
              onCopy: _copyVisibleContent,
            ),
          ),
        const SizedBox(height: 8),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.2),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
          ),
          child: isRecording
              ? const Padding(
                  key: ValueKey('rec-indicator'),
                  padding: EdgeInsets.only(bottom: 4),
                  child: RecordingIndicator(),
                )
              : const SizedBox(
                  key: ValueKey('rec-indicator-empty'),
                  height: 4,
                ),
        ),
        GestureDetector(
          onLongPress: () {
            if (hasAnyContent && session.status == RecordingStatus.idle) {
              _saveAndClear(thenStartRecording: true);
            }
          },
          child: _FabRow(
            showPlus:
                hasAnyContent && session.status != RecordingStatus.recording,
            onPlus: () => _saveAndClear(thenStartRecording: false),
            onIdleTap: _onRecordFabIdleTap,
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildWideLayout(
    ThemeData theme,
    SessionState session,
    bool showTranscript,
    bool loadedFromHistory,
  ) {
    final isRecording = session.status == RecordingStatus.recording;
    final hasReport = session.report.isNotEmpty;
    final hasTranscript = session.transcript.isNotEmpty;
    final hasAnyContent = hasReport || hasTranscript || isRecording;
    final emailMode = _reportHasEdits || (loadedFromHistory && hasReport);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: Column(
              children: [
                Expanded(
                  child: _ContentCard(
                    showTranscript: showTranscript,
                    onReportEditStateChanged: (hasEdits) {
                      if (!mounted) return;
                      if (hasEdits != _reportHasEdits) {
                        setState(() => _reportHasEdits = hasEdits);
                      }
                    },
                  ),
                ),
                const SizedBox(height: 8),
                if (hasAnyContent)
                  _ActionRow(
                    emailMode: emailMode,
                    showingTranscript: showTranscript,
                    hasReport: hasReport,
                    hasTranscript: hasTranscript,
                    onToggleView: () {
                      setState(() => _showTranscript = !_showTranscript);
                    },
                    onSendEmail: _sendEmail,
                    onCopy: _copyVisibleContent,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          SizedBox(
            width: 120,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                AnimatedOpacity(
                  opacity: isRecording ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: RecordingIndicator(),
                  ),
                ),
                _FabRow(
                  showPlus: hasAnyContent &&
                      session.status != RecordingStatus.recording,
                  onPlus: () => _saveAndClear(thenStartRecording: false),
                  onIdleTap: _onRecordFabIdleTap,
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── ContentCard ─────────────────────────

class _ContentCard extends StatelessWidget {
  final bool showTranscript;
  final ValueChanged<bool> onReportEditStateChanged;

  const _ContentCard({
    required this.showTranscript,
    required this.onReportEditStateChanged,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, anim) =>
            FadeTransition(opacity: anim, child: child),
        child: showTranscript
            ? const TranscriptPanel(key: ValueKey('transcript'))
            : ReportPanel(
                key: const ValueKey('report'),
                onEditStateChanged: onReportEditStateChanged,
              ),
      ),
    );
  }
}

// ───────────────────────── ActionRow ─────────────────────────

class _ActionRow extends StatelessWidget {
  final bool emailMode;
  final bool showingTranscript;
  final bool hasReport;
  final bool hasTranscript;
  final VoidCallback onToggleView;
  final VoidCallback onSendEmail;
  final VoidCallback onCopy;

  const _ActionRow({
    required this.emailMode,
    required this.showingTranscript,
    required this.hasReport,
    required this.hasTranscript,
    required this.onToggleView,
    required this.onSendEmail,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget? leftButton;
    if (emailMode) {
      leftButton = OutlinedButton.icon(
        key: const Key('btn_send_email'),
        onPressed: onSendEmail,
        icon: const Icon(Icons.email_outlined, size: 18),
        label: const Text('Odeslat emailem'),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.anoteGreen,
          side: const BorderSide(color: AppColors.anoteGreen, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
      );
    } else if (hasReport || hasTranscript) {
      // Toggle button. Label reflects what you would switch TO.
      final canToggle = hasReport && hasTranscript;
      leftButton = OutlinedButton(
        key: const Key('btn_toggle_view'),
        onPressed: canToggle ? onToggleView : null,
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
        child: Text(showingTranscript ? 'Lékařská zpráva' : 'Přepis'),
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        leftButton ?? const SizedBox.shrink(),
        IconButton(
          key: const Key('btn_copy'),
          icon: const Icon(Icons.copy_outlined),
          tooltip: 'Kopírovat',
          onPressed: (hasReport || hasTranscript) ? onCopy : null,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
        ),
      ],
    );
  }
}

// ───────────────────────── FabRow (record + new) ─────────────────────────

class _FabRow extends StatelessWidget {
  /// Whether to show the "+" new-recording button on the right of the FAB.
  final bool showPlus;
  final VoidCallback onPlus;
  final VoidCallback onIdleTap;

  const _FabRow({
    required this.showPlus,
    required this.onPlus,
    required this.onIdleTap,
  });

  @override
  Widget build(BuildContext context) {
    const plusSize = 44.0;
    const gap = 12.0;
    // Balance so the RecordFAB stays centered in the row.
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const SizedBox(width: plusSize + gap),
        RecordFAB(onIdleTap: onIdleTap),
        const SizedBox(width: gap),
        SizedBox(
          width: plusSize,
          height: plusSize,
          child:
              showPlus ? _PlusButton(onTap: onPlus) : const SizedBox.shrink(),
        ),
      ],
    );
  }
}

class _PlusButton extends StatelessWidget {
  final VoidCallback onTap;
  const _PlusButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      shape: CircleBorder(
        side: BorderSide(
          color: theme.colorScheme.outline.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: InkWell(
        key: const Key('btn_new_recording'),
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Tooltip(
          message: 'Nová nahrávka',
          child: Icon(
            Icons.add,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            size: 24,
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── theme provider (re-exported) ─────────────────────────

final _themeModeProvider =
    StateNotifierProvider<_ThemeModeNotifier, ThemeMode>((ref) {
  return _ThemeModeNotifier();
});

class _ThemeModeNotifier extends StateNotifier<ThemeMode> {
  _ThemeModeNotifier() : super(ThemeMode.system);

  void toggle() {
    state = state == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
  }

  void setMode(ThemeMode mode) {
    state = mode;
  }
}

/// Export the theme mode provider so main.dart can use it.
final themeModeProvider = _themeModeProvider;
