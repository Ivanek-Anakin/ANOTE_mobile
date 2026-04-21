import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/constants.dart';
import '../models/device_capability.dart';
import '../models/session_state.dart';
import '../providers/session_provider.dart';
import '../services/report_service.dart';
import 'home_screen.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _storage = const FlutterSecureStorage();
  final _urlController = TextEditingController();
  final _tokenController = TextEditingController();
  final _azureWhisperUrlController = TextEditingController();
  final _azureWhisperKeyController = TextEditingController();

  bool _isTestingConnection = false;
  String? _connectionStatus;

  static const String _themePrefKey = 'theme_mode';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final url = await _storage.read(key: AppConstants.secureStorageKeyUrl);
    final token = await _storage.read(key: AppConstants.secureStorageKeyToken);
    final azureUrl =
        await _storage.read(key: AppConstants.secureStorageKeyAzureWhisperUrl);
    final azureKey =
        await _storage.read(key: AppConstants.secureStorageKeyAzureWhisperKey);
    setState(() {
      _urlController.text =
          (url?.isEmpty ?? true) ? AppConstants.defaultBackendUrl : url!;
      _tokenController.text =
          (token?.isEmpty ?? true) ? AppConstants.defaultToken : token!;
      _azureWhisperUrlController.text = (azureUrl?.isEmpty ?? true)
          ? AppConstants.defaultAzureWhisperUrl
          : azureUrl!;
      _azureWhisperKeyController.text = (azureKey?.isEmpty ?? true)
          ? AppConstants.defaultAzureWhisperKey
          : azureKey!;
    });
  }

  Future<void> _saveSettings() async {
    await _storage.write(
      key: AppConstants.secureStorageKeyUrl,
      value: _urlController.text.trim(),
    );
    await _storage.write(
      key: AppConstants.secureStorageKeyToken,
      value: _tokenController.text.trim(),
    );
    await _storage.write(
      key: AppConstants.secureStorageKeyAzureWhisperUrl,
      value: _azureWhisperUrlController.text.trim(),
    );
    await _storage.write(
      key: AppConstants.secureStorageKeyAzureWhisperKey,
      value: _azureWhisperKeyController.text.trim(),
    );
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nastavení uložena')),
      );
    }
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTestingConnection = true;
      _connectionStatus = null;
    });

    final service = ReportService();
    final reachable = await service.isBackendReachable();

    setState(() {
      _isTestingConnection = false;
      _connectionStatus =
          reachable ? '✅ Backend dostupný' : '❌ Backend nedostupný';
    });
  }

  @override
  void dispose() {
    _urlController.dispose();
    _tokenController.dispose();
    _azureWhisperUrlController.dispose();
    _azureWhisperKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final currentThemeMode = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nastavení'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Připojení k backendu',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                labelText: 'URL backendu',
                hintText: 'https://anote-api.westeurope.azurecontainerapps.io',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.url,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _tokenController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'API Bearer Token',
                hintText: 'Váš tajný token',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _saveSettings,
                    child: const Text('Uložit nastavení'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _isTestingConnection ? null : _testConnection,
                    child: _isTestingConnection
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Test připojení'),
                  ),
                ),
              ],
            ),
            if (_connectionStatus != null) ...[
              const SizedBox(height: 8),
              Text(_connectionStatus!, style: theme.textTheme.bodyMedium),
            ],
            const Divider(height: 32),
            Text('Vzhled',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(value: ThemeMode.light, label: Text('Světlý')),
                ButtonSegment(value: ThemeMode.system, label: Text('Systém')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Tmavý')),
              ],
              selected: {currentThemeMode},
              onSelectionChanged: (modes) async {
                final mode = modes.first;
                ref.read(themeModeProvider.notifier).setMode(mode);
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString(_themePrefKey, mode.name);
              },
            ),
            const Divider(height: 32),
            Text('Typ návštěvy',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Ovlivňuje strukturu generované zprávy.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Consumer(
              builder: (context, ref, _) {
                final currentVisitType = ref.watch(visitTypeProvider);
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: VisitType.values.map((vt) {
                    final selected = vt == currentVisitType;
                    return ChoiceChip(
                      label: Text(vt.label),
                      selected: selected,
                      onSelected: (_) {
                        ref.read(visitTypeProvider.notifier).setVisitType(vt);
                        ref
                            .read(sessionProvider.notifier)
                            .markVisitTypeChanged();
                      },
                    );
                  }).toList(),
                );
              },
            ),
            const Divider(height: 32),
            Text('Automatické odesílání zprávy',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'Po dokončení zprávy ji automaticky odešle e-mailem.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Consumer(
              builder: (context, ref, _) {
                final emailEnabled = ref.watch(emailReportEnabledProvider);
                final emailAddress = ref.watch(emailReportAddressProvider);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Odesílat zprávu e-mailem'),
                      value: emailEnabled,
                      onChanged: (value) {
                        ref
                            .read(emailReportEnabledProvider.notifier)
                            .setEnabled(value);
                      },
                    ),
                    if (emailEnabled) ...[
                      TextField(
                        controller: TextEditingController(text: emailAddress)
                          ..selection = TextSelection.collapsed(
                              offset: emailAddress.length),
                        decoration: const InputDecoration(
                          labelText: 'E-mailová adresa',
                          hintText: 'lekar@nemocnice.cz',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.emailAddress,
                        onChanged: (value) {
                          ref
                              .read(emailReportAddressProvider.notifier)
                              .setAddress(value.trim());
                        },
                      ),
                      const SizedBox(height: 4),
                      if (emailAddress.isNotEmpty &&
                          !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                              .hasMatch(emailAddress))
                        Text(
                          'Zadejte platnou e-mailovou adresu.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                    ],
                  ],
                );
              },
            ),
            const Divider(height: 32),
            Text('Rozpoznávání řeči',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            Consumer(
              builder: (context, ref, _) {
                final currentModel = ref.watch(transcriptionModelProvider);
                final sessionState = ref.watch(sessionProvider);
                final capability = ref.watch(deviceCapabilityProvider);
                final isRecording =
                    sessionState.status == RecordingStatus.recording;
                final turboBlocked =
                    capability.turboStatus == TurboCapabilityStatus.blocked;
                final turboDiscouraged =
                    capability.turboStatus == TurboCapabilityStatus.discouraged;
                final turboUnknown =
                    capability.turboStatus == TurboCapabilityStatus.unknown;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SegmentedButton<TranscriptionModel>(
                      segments: [
                        ButtonSegment(
                          value: TranscriptionModel.small,
                          label: Text(TranscriptionModel.small.label),
                        ),
                        ButtonSegment(
                          value: TranscriptionModel.turbo,
                          label: Text(TranscriptionModel.turbo.label),
                          enabled: !turboBlocked,
                        ),
                        ButtonSegment(
                          value: TranscriptionModel.cloud,
                          label: Text(TranscriptionModel.cloud.label),
                        ),
                        ButtonSegment(
                          value: TranscriptionModel.hybrid,
                          label: Text(TranscriptionModel.hybrid.label),
                        ),
                      ],
                      selected: {currentModel},
                      onSelectionChanged: isRecording
                          ? null
                          : (models) {
                              final model = models.first;
                              ref
                                  .read(transcriptionModelProvider.notifier)
                                  .setModel(model);
                              // Trigger download/load of the selected model
                              ref
                                  .read(sessionProvider.notifier)
                                  .switchToModel(model);
                            },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      currentModel.description,
                      style: theme.textTheme.bodySmall,
                    ),
                    if (turboBlocked &&
                        currentModel != TranscriptionModel.turbo) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Turbo bylo po předchozím selhání na tomto zařízení vypnuto.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ],
                    if ((turboDiscouraged || turboUnknown) &&
                        currentModel == TranscriptionModel.turbo) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Turbo na tomto zařízení nebylo ověřeno — experimentální.',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.tertiary),
                      ),
                    ],
                    if (currentModel == TranscriptionModel.cloud ||
                        currentModel == TranscriptionModel.hybrid) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _azureWhisperUrlController,
                        decoration: const InputDecoration(
                          labelText: 'Azure Whisper URL',
                          hintText:
                              'https://{resource}.openai.azure.com/openai/deployments/{deployment}/audio/transcriptions?api-version=2024-06-01',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: TextInputType.url,
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _azureWhisperKeyController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Azure Whisper API Key',
                          hintText: 'Váš API klíč',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                    if (isRecording)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Nelze změnit model během nahrávání.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 8),
            const _InfoRow(label: 'Jazyk', value: 'čeština (cs)'),
            const Divider(height: 32),
            Text('O aplikaci',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            const Text('ANOTE Mobile v1.0.0'),
            const SizedBox(height: 4),
            Text(
              'Generování lékařských zpráv z hlasu.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text('$label: ',
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
      ],
    );
  }
}
