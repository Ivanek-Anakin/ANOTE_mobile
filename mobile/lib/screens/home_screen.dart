import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';
import '../widgets/report_panel.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/recording_controls.dart';
import '../widgets/recording_history_list.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _reportExpanded = true;

  @override
  void initState() {
    super.initState();
    // Preload model after first frame to avoid blocking UI
    SchedulerBinding.instance.addPostFrameCallback((_) {
      ref.read(sessionProvider.notifier).preloadModel();
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final isWide = width > 900;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.medical_services, size: 24),
            SizedBox(width: 8),
            Text('ANOTE'),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('btn_settings'),
            icon: const Icon(Icons.settings),
            tooltip: 'Nastavení',
            onPressed: () => Navigator.pushNamed(context, '/settings'),
          ),
          Consumer(
            builder: (context, ref, _) {
              final brightness = Theme.of(context).brightness;
              return IconButton(
                icon: Icon(
                  brightness == Brightness.dark
                      ? Icons.light_mode
                      : Icons.dark_mode,
                ),
                tooltip: brightness == Brightness.dark
                    ? 'Světlý režim'
                    : 'Tmavý režim',
                onPressed: () {
                  final notifier = ref.read(_themeModeProvider.notifier);
                  notifier.toggle();
                },
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _StatusPill(
              status: session.status, errorMessage: session.errorMessage),
          if (session.modelDownloadProgress != null)
            Padding(
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
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
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
            ),
          if (session.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      session.errorMessage!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
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
                          onPressed: () => ref
                              .read(sessionProvider.notifier)
                              .retryModelLoad(),
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text('Zkusit znovu'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            foregroundColor: theme.colorScheme.error,
                            side: BorderSide(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                    ),
                  // Retry report generation after timeout / network error
                  if (session.isModelLoaded &&
                      session.transcript.isNotEmpty &&
                      session.status == RecordingStatus.idle)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: SizedBox(
                        height: 28,
                        child: OutlinedButton.icon(
                          onPressed: () => ref
                              .read(sessionProvider.notifier)
                              .regenerateReport(),
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text('Zkusit znovu'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            textStyle: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                            foregroundColor: theme.colorScheme.error,
                            side: BorderSide(color: theme.colorScheme.error),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: isWide ? _buildWideLayout(theme) : _buildNarrowLayout(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrowLayout(ThemeData theme) {
    final screenHeight = MediaQuery.of(context).size.height;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_reportExpanded)
            SizedBox(
              height: screenHeight * 0.55,
              child: ReportPanel(
                onClose: () => setState(() => _reportExpanded = false),
              ),
            )
          else
            Card(
              child: InkWell(
                onTap: () => setState(() => _reportExpanded = true),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
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
                      Icon(Icons.expand_more,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.6)),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          const TranscriptPanel(),
          const SizedBox(height: 12),
          const RecordingControls(),
          const SizedBox(height: 12),
          const RecordingHistoryList(),
        ],
      ),
    );
  }

  Widget _buildWideLayout(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 2,
            child: const ReportPanel(),
          ),
          const SizedBox(width: 16),
          Expanded(
            flex: 1,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TranscriptPanel(),
                  const SizedBox(height: 12),
                  const RecordingControls(),
                  const SizedBox(height: 12),
                  const RecordingHistoryList(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Theme mode provider for toggling
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

// Status pill widget
class _StatusPill extends StatefulWidget {
  final RecordingStatus status;
  final String? errorMessage;

  const _StatusPill({required this.status, this.errorMessage});

  @override
  State<_StatusPill> createState() => _StatusPillState();
}

class _StatusPillState extends State<_StatusPill>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _opacity = Tween<double>(begin: 1.0, end: 0.3).animate(_controller);
    _updateAnimation();
  }

  @override
  void didUpdateWidget(_StatusPill old) {
    super.didUpdateWidget(old);
    _updateAnimation();
  }

  void _updateAnimation() {
    if (widget.status == RecordingStatus.recording) {
      _controller.repeat(reverse: true);
    } else {
      _controller.stop();
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (label, color) = switch (widget.status) {
      RecordingStatus.idle => widget.errorMessage != null
          ? ('Chyba', theme.colorScheme.error)
          : ('Připraveno', Colors.green.shade600),
      RecordingStatus.recording => (
          'Nahrávání & generování...',
          Colors.green.shade600
        ),
      RecordingStatus.processing => ('Dokončování...', Colors.green.shade600),
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: FadeTransition(
          opacity: _opacity,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: color, width: 1.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: color,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Export the theme mode provider so main.dart can use it
final themeModeProvider = _themeModeProvider;
