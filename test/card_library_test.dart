import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tagentra/card_library.dart';

void main() {
  test('persists, searches, compares, and preserves an original', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    addTearDown(() => root.delete(recursive: true));
    final library = CardLibrary(root);
    await library.open();
    final first = await library.save(
      name: 'Lab MFC',
      protocol: CardProtocol.mifareClassic,
      cardType: 'MIFARE Classic 1K',
      uid: '01020304',
      bytes: Uint8List.fromList([1, 2, 3]),
      format: 'mfd',
      rrgRevision: 'aaacc75',
      tags: const ['lab'],
      originalBytes: Uint8List.fromList([9]),
      originalExtension: 'mfd',
    );
    final second = await library.save(
      name: 'Copy',
      protocol: CardProtocol.mifareClassic,
      cardType: 'MIFARE Classic 1K',
      uid: '05060708',
      bytes: Uint8List.fromList([1, 4, 3]),
      format: 'bin',
      rrgRevision: 'aaacc75',
    );
    expect(library.search('lab').single.id, first.id);
    expect(await library.compare(first, second), [1]);
    final renamed = await library.updateMetadata(
      first.id,
      name: 'Renamed',
      notes: 'verified',
    );
    expect(renamed.name, 'Renamed');
    final reopened = CardLibrary(root);
    await reopened.open();
    expect(reopened.cards, hasLength(2));
    expect(reopened.cards.first.originalFile, isNotNull);
  });

  test('safe writes reject capacity mismatch and unknown protocols', () {
    expect(
      () => SafeWriteRequest(
        protocol: CardProtocol.mfuNtag,
        expectedBytes: 4,
        payload: Uint8List(3),
        targetDescription: 'test',
      ).validate(),
      throwsStateError,
    );
    expect(
      () => SafeWriteRequest(
        protocol: CardProtocol.unknown,
        expectedBytes: 3,
        payload: Uint8List(3),
        targetDescription: 'test',
      ).validate(),
      throwsStateError,
    );
  });

  test(
    'safe write orders backup, confirmation, write and verification',
    () async {
      final calls = <String>[];
      await const SafeWriteGuard().run(
        request: SafeWriteRequest(
          protocol: CardProtocol.iso15693,
          expectedBytes: 2,
          payload: Uint8List(2),
          targetDescription: 'test card',
        ),
        backup: () async => calls.add('backup'),
        confirm: (_) async {
          calls.add('confirm');
          return true;
        },
        write: () async => calls.add('write'),
        verify: () async {
          calls.add('verify');
          return true;
        },
      );
      expect(calls, ['backup', 'confirm', 'write', 'verify']);
    },
  );
}
