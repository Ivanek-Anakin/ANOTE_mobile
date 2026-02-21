import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/session_provider.dart';

class ReportPanel extends ConsumerWidget {
  const ReportPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionProvider);
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('📋', style: TextStyle(fontSize: 20)),
                const SizedBox(width: 8),
                Text(
                  'Lékařská zpráva',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                controller: TextEditingController(text: session.report),
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
}
