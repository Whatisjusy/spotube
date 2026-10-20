import 'dart:io';

/// False only for a FLAC file whose metadata does not end where the first
/// audio frame starts. Rewriting tags into a cached FLAC without padding has
/// left the audio a few KB away from where the header says it is; such a
/// file plays as a burst of noise or fails to decode at all. Files that are
/// not FLAC inside are left to the decoder.
Future<bool> flacLooksPlayable(File file) async {
  final raf = await file.open();
  try {
    final magic = await raf.read(4);
    if (magic.length < 4 || String.fromCharCodes(magic) != "fLaC") return true;

    var offset = 4;
    for (var block = 0; block < 128; block++) {
      await raf.setPosition(offset);
      final header = await raf.read(4);
      if (header.length < 4) return false;
      final length = (header[1] << 16) | (header[2] << 8) | header[3];
      offset += 4 + length;
      if ((header[0] & 0x80) != 0) {
        await raf.setPosition(offset);
        final sync = await raf.read(2);
        return sync.length == 2 && sync[0] == 0xFF && (sync[1] & 0xFE) == 0xF8;
      }
    }
    return false;
  } finally {
    await raf.close();
  }
}
