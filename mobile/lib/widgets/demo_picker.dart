import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';

class DemoScenarioInfo {
  final String id;
  final String name;
  final String preview;
  final int wordCount;

  const DemoScenarioInfo({
    required this.id,
    required this.name,
    required this.preview,
    required this.wordCount,
  });
}

const _scenarioNames = {
  'cz_kardialni_nahoda': '🇨🇿 Kardiální nehoda',
  'cz_respiracni_infekce': '🇨🇿 Respirační infekce',
  'cz_detska_prohlidka': '🇨🇿 Dětská prohlídka',
  'cz_otrava_jidlem': '🇨🇿 Otrava jídlem',
  'cardiac_emergency': 'Cardiac Emergency',
  'food_poisoning': 'Food Poisoning',
  'pediatric_checkup': 'Pediatric Checkup',
  'respiratory_infection': 'Respiratory Infection',
};

const _scenarioFiles = [
  'cz_kardialni_nahoda',
  'cz_respiracni_infekce',
  'cz_detska_prohlidka',
  'cz_otrava_jidlem',
  'cardiac_emergency',
  'food_poisoning',
  'pediatric_checkup',
  'respiratory_infection',
];

final _scenariosProvider = FutureProvider<List<DemoScenarioInfo>>((ref) async {
  final scenarios = <DemoScenarioInfo>[];
  for (final id in _scenarioFiles) {
    try {
      final text = await rootBundle.loadString('assets/demo_scenarios/$id.txt');
      final words = text.trim().split(RegExp(r'\s+'));
      scenarios.add(DemoScenarioInfo(
        id: id,
        name: _scenarioNames[id] ?? id,
        preview: text.length > 120 ? '${text.substring(0, 120)}...' : text,
        wordCount: words.length,
      ));
    } catch (_) {
      // Skip if file not found
    }
  }
  return scenarios;
});

class DemoPicker extends ConsumerStatefulWidget {
  const DemoPicker({super.key});

  @override
  ConsumerState<DemoPicker> createState() => _DemoPickerState();
}

class _DemoPickerState extends ConsumerState<DemoPicker> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = ref.watch(sessionProvider);
    final notifier = ref.read(sessionProvider.notifier);
    final scenariosAsync = ref.watch(_scenariosProvider);
    final isDemoPlaying = session.status == RecordingStatus.demoPlaying;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.5),
          style: BorderStyle.solid,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          scenariosAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Chyba při načítání scénářů: $e'),
            ),
            data: (scenarios) => scenarios.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'Žádné demo scénáře k dispozici.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: scenarios.length,
                    itemBuilder: (context, index) {
                      final scenario = scenarios[index];
                      final isSelected = _selectedId == scenario.id;
                      return Card(
                        key: Key('demo_scenario_${scenario.id}'),
                        margin: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        color: isSelected
                            ? theme.colorScheme.primaryContainer
                            : null,
                        child: InkWell(
                          onTap: isDemoPlaying
                              ? null
                              : () => setState(() => _selectedId = scenario.id),
                          borderRadius: BorderRadius.circular(12),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  scenario.name,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    color: isSelected
                                        ? theme.colorScheme.onPrimaryContainer
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  scenario.preview,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: isSelected
                                        ? theme.colorScheme.onPrimaryContainer
                                            .withValues(alpha: 0.8)
                                        : theme.colorScheme.onSurface
                                            .withValues(alpha: 0.6),
                                  ),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${scenario.wordCount} slov',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface
                                        .withValues(alpha: 0.5),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: isDemoPlaying
                ? OutlinedButton.icon(
                    key: const Key('btn_demo_stop'),
                    onPressed: () => notifier.cancelDemo(),
                    icon: const Text('⬛'),
                    label: const Text('Zastavit simulaci'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                  )
                : FilledButton.icon(
                    key: const Key('btn_demo_start'),
                    onPressed: _selectedId != null
                        ? () => notifier.playDemo(_selectedId!)
                        : null,
                    icon: const Text('▶'),
                    label: const Text('Spustit simulaci'),
                  ),
          ),
        ],
      ),
    );
  }
}
