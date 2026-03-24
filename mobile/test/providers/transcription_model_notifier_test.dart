import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:anote_mobile/config/constants.dart';
import 'package:anote_mobile/models/session_state.dart';
import 'package:anote_mobile/providers/session_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TranscriptionModelNotifier', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('initial state is small', () {
      final notifier = TranscriptionModelNotifier();
      expect(notifier.state, TranscriptionModel.small);
    });

    test('_load reads from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.transcriptionModelPrefKey: 'turbo',
      });

      final notifier = TranscriptionModelNotifier();
      // Allow the async _load() to run
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state, TranscriptionModel.turbo);
    });

    test('_load defaults to small for missing key', () async {
      SharedPreferences.setMockInitialValues({});

      final notifier = TranscriptionModelNotifier();
      await Future<void>.delayed(Duration.zero);
      expect(notifier.state, TranscriptionModel.small);
    });

    test('setModel updates state and persists', () async {
      SharedPreferences.setMockInitialValues({});

      final notifier = TranscriptionModelNotifier();
      await Future<void>.delayed(Duration.zero);

      await notifier.setModel(TranscriptionModel.cloud);
      expect(notifier.state, TranscriptionModel.cloud);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppConstants.transcriptionModelPrefKey),
        'cloud',
      );
    });

    test('setModel to turbo persists turbo', () async {
      SharedPreferences.setMockInitialValues({});

      final notifier = TranscriptionModelNotifier();
      await Future<void>.delayed(Duration.zero);

      await notifier.setModel(TranscriptionModel.turbo);
      expect(notifier.state, TranscriptionModel.turbo);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppConstants.transcriptionModelPrefKey),
        'turbo',
      );
    });

    test('setModel can switch back to small', () async {
      SharedPreferences.setMockInitialValues({
        AppConstants.transcriptionModelPrefKey: 'cloud',
      });

      final notifier = TranscriptionModelNotifier();
      await Future<void>.delayed(Duration.zero);

      await notifier.setModel(TranscriptionModel.small);
      expect(notifier.state, TranscriptionModel.small);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(AppConstants.transcriptionModelPrefKey),
        'small',
      );
    });
  });
}
