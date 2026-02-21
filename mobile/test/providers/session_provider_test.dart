import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:anote_mobile/models/session_state.dart';
import 'package:anote_mobile/providers/session_provider.dart';
import 'package:anote_mobile/services/report_service.dart';

import 'session_provider_test.mocks.dart';

@GenerateMocks([ReportService])
void main() {
  late MockReportService mockReportService;

  setUp(() {
    mockReportService = MockReportService();
  });

  ProviderContainer makeContainer() {
    return ProviderContainer(
      overrides: [
        reportServiceProvider.overrideWithValue(mockReportService),
      ],
    );
  }

  test('initial state is idle with empty transcript and report', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.idle);
    expect(state.transcript, isEmpty);
    expect(state.report, isEmpty);
    expect(state.errorMessage, isNull);
  });

  test('startRecording sets status to recording', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).startRecording();
    expect(container.read(sessionProvider).status, RecordingStatus.recording);
  });

  test('stopRecording sets status to idle', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).startRecording();
    container.read(sessionProvider.notifier).stopRecording();
    expect(container.read(sessionProvider).status, RecordingStatus.idle);
  });

  test('resetSession clears all fields', () {
    final container = makeContainer();
    addTearDown(container.dispose);

    container.read(sessionProvider.notifier).startRecording();
    container.read(sessionProvider.notifier).resetSession();

    final state = container.read(sessionProvider);
    expect(state.status, RecordingStatus.idle);
    expect(state.transcript, isEmpty);
    expect(state.report, isEmpty);
    expect(state.errorMessage, isNull);
  });

  test('generateReportFromText updates state.report', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    when(mockReportService.generateReport(any))
        .thenAnswer((_) async => 'Generated medical report');

    await container
        .read(sessionProvider.notifier)
        .generateReportFromText('Pacient přišel s bolestí hlavy.');

    final state = container.read(sessionProvider);
    expect(state.report, 'Generated medical report');
    expect(state.status, RecordingStatus.idle);
  });

  test('generateReportFromText sets error on failure', () async {
    final container = makeContainer();
    addTearDown(container.dispose);

    when(mockReportService.generateReport(any))
        .thenThrow(const ReportServerException('Server error'));

    await container
        .read(sessionProvider.notifier)
        .generateReportFromText('test');

    final state = container.read(sessionProvider);
    expect(state.errorMessage, isNotNull);
    expect(state.status, RecordingStatus.idle);
  });
}
