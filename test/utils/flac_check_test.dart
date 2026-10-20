import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:spotube/utils/flac_check.dart';

/// "fLaC", one STREAMINFO block (34 bytes, marked last), then [audio].
List<int> flac({required bool last, required List<int> audio}) => [
      ...'fLaC'.codeUnits,
      last ? 0x80 : 0x00, 0, 0, 34, ...List.filled(34, 0),
      if (!last) ...[0x81, 0, 0, 4, 0, 0, 0, 0], // PADDING, last
      ...audio,
    ];

void main() {
  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp("flac"));
  tearDown(() async => dir.delete(recursive: true));

  Future<bool> check(List<int> bytes) async {
    final file = File("${dir.path}/t.flac")..writeAsBytesSync(bytes);
    return flacLooksPlayable(file);
  }

  test("audio frame right after the metadata is playable", () async {
    expect(await check(flac(last: true, audio: [0xFF, 0xF8, 1, 2])), isTrue);
    expect(await check(flac(last: false, audio: [0xFF, 0xF9, 1, 2])), isTrue);
  });

  test("metadata pointing off the first frame is damaged", () async {
    // Like the damaged cache files: a stray padding header where audio
    // should start, the real frame a few KB later.
    expect(
      await check(flac(last: true, audio: [0x81, 0, 4, 0, 0xFF, 0xF8])),
      isFalse,
    );
  });

  test("not FLAC inside (AAC saved as .flac) is left alone", () async {
    expect(await check([0, 0, 0, 0x1c, ...'ftypisom'.codeUnits]), isTrue);
  });

  test("truncated metadata is damaged", () async {
    expect(await check([...'fLaC'.codeUnits, 0x00, 0, 0]), isFalse);
  });
}
