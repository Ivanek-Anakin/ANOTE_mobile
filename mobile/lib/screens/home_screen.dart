import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';
import '../widgets/report_panel.dart';
import '../widgets/transcript_panel.dart';
import '../widgets/recording_controls.dart';
import '../widgets/demo_picker.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _showDemo = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;
    final isWide = width > 900;

    return Scaffold(
      appBar: AppBar(
        title: const Text('🩺 ANOTE'),
        actions: [
          IconButton(
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
          if (session.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                session.errorMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 300,
            child: const ReportPanel(),
          ),
          const SizedBox(height: 12),
          const TranscriptPanel(),
          const SizedBox(height: 12),
          const RecordingControls(),
          const SizedBox(height: 12),
          _buildDemoSection(theme),
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
                  _buildDemoSection(theme),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDemoSection(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: () => setState(() => _showDemo = !_showDemo),
          icon: const Text('🎬'),
          label: const Text('Demo / Prezentační režim'),
          style: OutlinedButton.styleFrom(
            side: BorderSide(
              color: theme.colorScheme.outline,
              style: BorderStyle.solid,
            ),
          ),
        ),
        if (_showDemo) ...[
          const SizedBox(height: 8),
          const DemoPicker(),
        ],
      ],
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
    if (widget.status == RecordingStatus.recording ||
        widget.status == RecordingStatus.demoPlaying) {
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
      RecordingStatus.demoPlaying => ('Simulace...', Colors.green.shade600),
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
