import 'package:flutter_test/flutter_test.dart';
import 'package:anote_mobile/services/whisper_service.dart';

void main() {
  group('WhisperService.removeOverlap', () {
    test('removes overlapping words between previous tail and new text', () {
      const String previousTail = 'bolest na hrudi trvající dva';
      const String newText =
          'trvající dva dny s vyzařováním do levé ruky';
      final String result =
          WhisperService.removeOverlap(previousTail, newText);
      expect(result, 'dny s vyzařováním do levé ruky');
    });

    test('returns newText unchanged when there is no overlap', () {
      const String previousTail = 'pacient má teplotu';
      const String newText = 'a bolesti v krku';
      expect(
        WhisperService.removeOverlap(previousTail, newText),
        'a bolesti v krku',
      );
    });

    test('returns newText when previousTail is empty', () {
      expect(
        WhisperService.removeOverlap('', 'nový text'),
        'nový text',
      );
    });

    test('returns newText when newText is empty', () {
      expect(WhisperService.removeOverlap('tail text', ''), '');
    });

    test('handles diacritics during comparison', () {
      // "trvající dva" vs "trvajici dva" — normalised match
      const String previousTail = 'bolest trvající dva';
      const String newText = 'trvající dva dny';
      expect(
        WhisperService.removeOverlap(previousTail, newText),
        'dny',
      );
    });

    test('returns empty string when newText is entirely overlap', () {
      const String previousTail = 'celý přepis věty';
      const String newText = 'celý přepis věty';
      expect(WhisperService.removeOverlap(previousTail, newText), '');
    });
  });

  group('WhisperService sliding window', () {
    test('triggers transcription after 5 seconds (80000 samples) of new audio',
        () async {
      int callCount = 0;
      final service = WhisperService.withTranscriber((samples) async {
        callCount++;
        return 'přepis';
      });

      // Feed exactly one window interval worth of samples
      service.feedAudio(List<double>.filled(80000, 0.0));

      // Let the async transcription complete
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(callCount, 1);
    });

    test('does not trigger transcription before 5 seconds of new audio',
        () async {
      int callCount = 0;
      final service = WhisperService.withTranscriber((samples) async {
        callCount++;
        return 'přepis';
      });

      // Feed less than one window (79999 samples)
      service.feedAudio(List<double>.filled(79999, 0.0));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(callCount, 0);
    });

    test('does not trigger a second transcription while one is in progress',
        () async {
      int callCount = 0;
      final service = WhisperService.withTranscriber((samples) async {
        callCount++;
        // Simulate a slow transcription
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return 'přepis';
      });

      // Feed two windows worth — but the second should be skipped while
      // the first is still in progress.
      service.feedAudio(List<double>.filled(80000, 0.0));
      service.feedAudio(List<double>.filled(80000, 0.0));

      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Only one transcription should have been triggered so far
      expect(callCount, 1);
    });
  });

  group('WhisperService.reset', () {
    test('clears all buffers and state', () async {
      int callCount = 0;
      final service = WhisperService.withTranscriber((samples) async {
        callCount++;
        return 'přepis';
      });

      // Feed enough audio to accumulate state
      service.feedAudio(List<double>.filled(80000, 0.0));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Reset
      service.reset();

      // After reset, feeding fewer than a full window should NOT trigger
      // transcription (lastBoundary and buffer are both at 0)
      callCount = 0;
      service.feedAudio(List<double>.filled(40000, 0.0));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(callCount, 0);
    });

    test('transcribeFull returns empty string after reset with no audio', () async {
      final service = WhisperService.withTranscriber((samples) async => 'text');
      service.reset();
      final result = await service.transcribeFull();
      expect(result, '');
    });
  });

  group('WhisperService.transcribeFull', () {
    test('calls transcriber with entire audio buffer', () async {
      List<double>? capturedSamples;
      final service = WhisperService.withTranscriber((samples) async {
        capturedSamples = samples;
        return 'full transcript';
      });

      final input = List<double>.filled(32000, 0.1);
      service.feedAudio(input);

      // Wait for any pending window transcription to complete
      await Future<void>.delayed(const Duration(milliseconds: 10));

      final result = await service.transcribeFull();
      expect(result, 'full transcript');
      expect(capturedSamples?.length, input.length);
    });

    test('returns empty string when no audio has been fed', () async {
      final service = WhisperService.withTranscriber((samples) async => 'x');
      expect(await service.transcribeFull(), '');
    });
  });
}
