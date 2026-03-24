import 'package:flutter_test/flutter_test.dart';
import 'package:anote_mobile/services/whisper_service.dart';

void main() {
  group('WhisperModelConfig registry', () {
    test('smallConfig has correct file names', () {
      final c = WhisperService.smallConfig;
      expect(c.encoderFile, 'small-encoder.int8.onnx');
      expect(c.decoderFile, 'small-decoder.int8.onnx');
      expect(c.tokensFile, 'small-tokens.txt');
    });

    test('smallConfig dir and URL are set', () {
      final c = WhisperService.smallConfig;
      expect(c.dirName, isNotEmpty);
      expect(c.baseUrl, contains('huggingface.co'));
    });

    test('smallConfig expectedMinSizes includes encoder and decoder', () {
      final c = WhisperService.smallConfig;
      expect(c.expectedMinSizes, contains(c.encoderFile));
      expect(c.expectedMinSizes, contains(c.decoderFile));
      expect(c.expectedMinSizes, contains(c.tokensFile));
    });

    test('turboConfig has correct file names', () {
      final c = WhisperService.turboConfig;
      expect(c.encoderFile, 'large-v3-turbo-encoder.int8.onnx');
      expect(c.decoderFile, 'large-v3-turbo-decoder.int8.onnx');
      expect(c.tokensFile, 'large-v3-turbo-tokens.txt');
    });

    test('turboConfig dir and URL are set', () {
      final c = WhisperService.turboConfig;
      expect(c.dirName, isNotEmpty);
      expect(c.baseUrl, contains('huggingface.co'));
    });

    test('turboConfig expectedMinSizes includes encoder and decoder', () {
      final c = WhisperService.turboConfig;
      expect(c.expectedMinSizes, contains(c.encoderFile));
      expect(c.expectedMinSizes, contains(c.decoderFile));
      expect(c.expectedMinSizes, contains(c.tokensFile));
    });

    test('small and turbo have different dir names', () {
      expect(
        WhisperService.smallConfig.dirName,
        isNot(WhisperService.turboConfig.dirName),
      );
    });

    test('sizeMB is positive for both configs', () {
      expect(WhisperService.smallConfig.sizeMB, greaterThan(0));
      expect(WhisperService.turboConfig.sizeMB, greaterThan(0));
    });

    test('turbo model is larger than small', () {
      expect(
        WhisperService.turboConfig.sizeMB,
        greaterThan(WhisperService.smallConfig.sizeMB),
      );
    });
  });
}
