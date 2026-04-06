import 'dart:typed_data';

/// Encodes raw PCM float32 audio samples to WAV byte format.
class WavEncoder {
  /// Encode float32 PCM [samples] to WAV bytes.
  ///
  /// Samples are expected in the range [-1.0, 1.0].
  /// Values outside this range are clamped.
  /// Output is 16-bit PCM mono WAV at [sampleRate] Hz.
  static Uint8List encode(List<double> samples, {int sampleRate = 16000}) {
    final int numSamples = samples.length;
    final int dataSize = numSamples * 2; // 2 bytes per int16 sample
    final int fileSize = 36 + dataSize; // RIFF chunk size = fileSize - 8
    final int byteRate =
        sampleRate * 1 * 2; // sampleRate * channels * bytesPerSample

    final buffer = ByteData(44 + dataSize);

    // RIFF chunk descriptor
    buffer.setUint8(0, 0x52); // R
    buffer.setUint8(1, 0x49); // I
    buffer.setUint8(2, 0x46); // F
    buffer.setUint8(3, 0x46); // F
    buffer.setUint32(4, fileSize, Endian.little);
    buffer.setUint8(8, 0x57); // W
    buffer.setUint8(9, 0x41); // A
    buffer.setUint8(10, 0x56); // V
    buffer.setUint8(11, 0x45); // E

    // fmt sub-chunk
    buffer.setUint8(12, 0x66); // f
    buffer.setUint8(13, 0x6D); // m
    buffer.setUint8(14, 0x74); // t
    buffer.setUint8(15, 0x20); // (space)
    buffer.setUint32(16, 16, Endian.little); // Subchunk1Size = 16 for PCM
    buffer.setUint16(20, 1, Endian.little); // AudioFormat = PCM (1)
    buffer.setUint16(22, 1, Endian.little); // NumChannels = 1 (mono)
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(
        32, 2, Endian.little); // BlockAlign = channels * bitsPerSample/8
    buffer.setUint16(34, 16, Endian.little); // BitsPerSample = 16

    // data sub-chunk
    buffer.setUint8(36, 0x64); // d
    buffer.setUint8(37, 0x61); // a
    buffer.setUint8(38, 0x74); // t
    buffer.setUint8(39, 0x61); // a
    buffer.setUint32(40, dataSize, Endian.little);

    // PCM data — convert float32 [-1.0, 1.0] to int16 [-32767, 32767]
    for (int i = 0; i < numSamples; i++) {
      final double clamped = samples[i].clamp(-1.0, 1.0);
      final int int16 = (clamped * 32767).round();
      buffer.setInt16(44 + i * 2, int16, Endian.little);
    }

    return buffer.buffer.asUint8List();
  }

  /// Downsample by factor of 2 using adjacent sample averaging.
  /// 16kHz → 8kHz is well-suited for speech and halves upload size.
  static List<double> downsample2x(List<double> samples) {
    final int outLen = samples.length ~/ 2;
    final result = List<double>.filled(outLen, 0.0);
    for (int i = 0; i < outLen; i++) {
      result[i] = (samples[i * 2] + samples[i * 2 + 1]) / 2.0;
    }
    return result;
  }
}
