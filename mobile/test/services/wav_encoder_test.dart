import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anote_mobile/utils/wav_encoder.dart';

void main() {
  group('WavEncoder', () {
    test('encodes 1 second of silence to a valid 32044-byte WAV file', () {
      final List<double> samples = List<double>.filled(16000, 0.0);
      final Uint8List wav = WavEncoder.encode(samples);

      // Total size: 44 (header) + 16000 * 2 (int16 data) = 32044
      expect(wav.length, 44 + 16000 * 2);

      // Check RIFF magic bytes
      expect(wav[0], equals(0x52)); // R
      expect(wav[1], equals(0x49)); // I
      expect(wav[2], equals(0x46)); // F
      expect(wav[3], equals(0x46)); // F

      // Check WAVE marker at offset 8
      expect(wav[8], equals(0x57)); // W
      expect(wav[9], equals(0x41)); // A
      expect(wav[10], equals(0x56)); // V
      expect(wav[11], equals(0x45)); // E

      // Check "data" sub-chunk at offset 36
      expect(wav[36], equals(0x64)); // d
      expect(wav[37], equals(0x61)); // a
      expect(wav[38], equals(0x74)); // t
      expect(wav[39], equals(0x61)); // a
    });

    test('encoding empty list produces a valid WAV header with zero data', () {
      final Uint8List wav = WavEncoder.encode([]);

      // Header only (44 bytes), no data
      expect(wav.length, 44);

      // RIFF magic
      expect(wav[0], equals(0x52));
      expect(wav[3], equals(0x46));

      // data sub-chunk size should be 0
      final int dataSize = ByteData.view(wav.buffer).getUint32(40, Endian.little);
      expect(dataSize, 0);
    });

    test('clamps values above 1.0 to max int16', () {
      final Uint8List wav = WavEncoder.encode([2.0]);
      final ByteData bd = ByteData.view(wav.buffer);
      final int sample = bd.getInt16(44, Endian.little);
      // 1.0 * 32767 = 32767
      expect(sample, equals(32767));
    });

    test('clamps values below -1.0 to min int16', () {
      final Uint8List wav = WavEncoder.encode([-2.0]);
      final ByteData bd = ByteData.view(wav.buffer);
      final int sample = bd.getInt16(44, Endian.little);
      // -1.0 * 32767 = -32767
      expect(sample, equals(-32767));
    });

    test('encodes a known positive sample correctly', () {
      final Uint8List wav = WavEncoder.encode([0.5]);
      final ByteData bd = ByteData.view(wav.buffer);
      final int sample = bd.getInt16(44, Endian.little);
      expect(sample, equals((0.5 * 32767).round()));
    });

    test('WAV header fields are correct for 16000 Hz mono 16-bit', () {
      final Uint8List wav = WavEncoder.encode(List<double>.filled(100, 0.0));
      final ByteData bd = ByteData.view(wav.buffer);

      // AudioFormat (PCM = 1) at offset 20
      expect(bd.getUint16(20, Endian.little), 1);
      // NumChannels = 1 at offset 22
      expect(bd.getUint16(22, Endian.little), 1);
      // SampleRate = 16000 at offset 24
      expect(bd.getUint32(24, Endian.little), 16000);
      // BitsPerSample = 16 at offset 34
      expect(bd.getUint16(34, Endian.little), 16);
    });
  });
}
