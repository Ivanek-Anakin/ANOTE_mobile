import 'package:flutter_test/flutter_test.dart';
import 'package:anote_mobile/models/session_state.dart';

void main() {
  group('TranscriptionModel', () {
    test('prefValue returns correct strings', () {
      expect(TranscriptionModel.small.prefValue, 'small');
      expect(TranscriptionModel.turbo.prefValue, 'turbo');
      expect(TranscriptionModel.cloud.prefValue, 'cloud');
    });

    test('label returns non-empty strings', () {
      for (final model in TranscriptionModel.values) {
        expect(model.label, isNotEmpty);
      }
    });

    test('description returns non-empty strings', () {
      for (final model in TranscriptionModel.values) {
        expect(model.description, isNotEmpty);
      }
    });

    test('fromString round-trips all values', () {
      for (final model in TranscriptionModel.values) {
        expect(
          TranscriptionModelApi.fromString(model.prefValue),
          model,
        );
      }
    });

    test('fromString defaults to small for null', () {
      expect(
        TranscriptionModelApi.fromString(null),
        TranscriptionModel.small,
      );
    });

    test('fromString defaults to small for unknown value', () {
      expect(
        TranscriptionModelApi.fromString('unknown'),
        TranscriptionModel.small,
      );
    });

    test('fromString defaults to small for empty string', () {
      expect(
        TranscriptionModelApi.fromString(''),
        TranscriptionModel.small,
      );
    });
  });
}
