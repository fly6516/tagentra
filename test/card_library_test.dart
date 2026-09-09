import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tagentra/card_library.dart';
import 'package:tagentra_pm3/tagentra_pm3.dart';

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

  test('pairs PM3 artifacts and parses all Key A before all Key B', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    final source = await Directory.systemTemp.createTemp(
      'tagentra-artifact-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    final dump = File('${source.path}/hf-mf-a1b2c3d4-dump.bin');
    final json = File('${source.path}/hf-mf-a1b2c3d4-dump.json');
    final key = File('${source.path}/hf-mf-a1b2c3d4-key.bin');
    await dump.writeAsBytes(Uint8List(1024));
    await json.writeAsString('{}');
    final keyBytes = Uint8List(16 * 12);
    for (var sector = 0; sector < 16; sector++) {
      keyBytes.fillRange(sector * 6, sector * 6 + 6, sector);
      keyBytes.fillRange((16 + sector) * 6, (17 + sector) * 6, 0x80 + sector);
    }
    await key.writeAsBytes(keyBytes);
    final artifacts = [dump, json, key].map(_artifact).toList(growable: false);

    final library = CardLibrary(root);
    await library.open();
    final result = await library.importPm3Artifacts(
      artifacts,
      rrgRevision: 'aaacc75',
    );

    expect(result.imported, hasLength(1));
    final card = result.imported.single;
    expect(card.cardType, 'MIFARE Classic 1K');
    expect(card.uid, 'A1B2C3D4');
    expect(card.unlockStatus, CardUnlockStatus.complete);
    expect(card.sectorKeys, hasLength(16));
    expect(card.sectorKeys[1].keyA, '010101010101');
    expect(card.sectorKeys[1].keyB, '818181818181');
    expect(card.artifacts.map((value) => value.kind), {
      CardArtifactKind.dumpBin,
      CardArtifactKind.dumpJson,
      CardArtifactKind.keyBin,
    });

    final repeated = await library.importPm3Artifacts(
      artifacts,
      rrgRevision: 'aaacc75',
    );
    expect(repeated.changed, isFalse);
    expect(library.cards, hasLength(1));
  });

  test('accepts Classic capacities and ignores malformed dumps', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    final source = await Directory.systemTemp.createTemp(
      'tagentra-artifact-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    final files = <File>[];
    for (final entry in {
      320: '01',
      1024: '02',
      2048: '03',
      4096: '04',
      1000: '05',
    }.entries) {
      final file = File('${source.path}/hf-mf-${entry.value}-dump.bin');
      await file.writeAsBytes(Uint8List(entry.key));
      files.add(file);
    }
    final library = CardLibrary(root);
    await library.open();
    await library.importPm3Artifacts(files.map(_artifact), rrgRevision: 'test');
    expect(
      library.cards.map((card) => card.cardType),
      containsAll([
        'MIFARE Classic Mini',
        'MIFARE Classic 1K',
        'MIFARE Classic 2K',
        'MIFARE Classic 4K',
      ]),
    );
    expect(library.cards, hasLength(4));
  });

  test('reports key-only recovery and migrates an old index', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    final source = await Directory.systemTemp.createTemp(
      'tagentra-artifact-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    await Directory('${root.path}/data').create(recursive: true);
    await File('${root.path}/index.json').writeAsString('''[
      {"id":"old","name":"Old","protocol":"mifareClassic","cardType":"MIFARE Classic 1K","uid":"0102","source":"import","createdAt":"2025-01-01T00:00:00Z","updatedAt":"2025-01-01T00:00:00Z","tags":[],"notes":"","dataFormat":"bin","dataFile":"old.bin","rrgRevision":"old","originalFile":null}
    ]''');
    final key = File('${source.path}/hf-mf-aabbccdd-key.bin');
    await key.writeAsBytes(Uint8List(192));
    final library = CardLibrary(root);
    await library.open();
    final result = await library.importPm3Artifacts([
      _artifact(key),
    ], rrgRevision: 'test');
    expect(library.cards.single.sourceArtifactIds, isEmpty);
    expect(library.cards.single.sectorKeys, isEmpty);
    expect(result.keysWithoutDump, ['AABBCCDD']);
  });

  test('edits, selects artifact files, and deletes managed files', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    final source = await Directory.systemTemp.createTemp(
      'tagentra-artifact-test-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => source.delete(recursive: true));
    final dump = File('${source.path}/hf-mf-01020304-dump.bin');
    final key = File('${source.path}/hf-mf-01020304-key.bin');
    await dump.writeAsBytes(Uint8List(1024));
    await key.writeAsBytes(Uint8List(192));
    final library = CardLibrary(root, artifactSourceRoot: source);
    await library.open();
    final imported = await library.importPm3Artifacts(
      [dump, key].map(_artifact),
      rrgRevision: 'test',
    );
    final edited = await library.updateMetadata(
      imported.imported.single.id,
      name: 'Door card',
      tags: ['office'],
      notes: 'verified',
    );
    expect(edited.name, 'Door card');
    final selected = library.filesForArtifacts(edited, {
      CardArtifactKind.keyBin,
    });
    expect(selected, hasLength(1));
    expect(selected.single.path, endsWith('-key.bin'));
    expect(await selected.single.exists(), isTrue);
    await library.delete(edited.id);
    expect(library.cards, isEmpty);
    expect(await selected.single.exists(), isFalse);
    expect(await dump.exists(), isFalse);
    expect(await key.exists(), isFalse);
  });

  test('splits Classic capacities into sectors and 16-byte blocks', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    addTearDown(() => root.delete(recursive: true));
    final library = CardLibrary(root);
    await library.open();

    final expectations = <int, ({int sectors, int blocks})>{
      320: (sectors: 5, blocks: 20),
      1024: (sectors: 16, blocks: 64),
      2048: (sectors: 32, blocks: 128),
      4096: (sectors: 40, blocks: 256),
    };
    for (final entry in expectations.entries) {
      final bytes = Uint8List.fromList(
        List.generate(entry.key, (index) => index & 0xff),
      );
      final card = await library.save(
        name: '${entry.key}',
        protocol: CardProtocol.mifareClassic,
        cardType: 'MIFARE Classic',
        uid: '${entry.key}',
        bytes: bytes,
        format: 'bin',
        rrgRevision: 'test',
      );

      final sectors = await library.readMifareSectors(card);
      expect(sectors, hasLength(entry.value.sectors));
      expect(
        sectors.expand((sector) => sector.blocks),
        hasLength(entry.value.blocks),
      );
      expect(sectors.first.blocks.first.block, 0);
      expect(sectors.first.blocks.first.offset, 0);
      expect(sectors.first.blocks.first.bytes, orderedEquals(bytes.take(16)));
      expect(sectors.first.blocks.last.isSectorTrailer, isTrue);
    }

    final fourK = await library.readMifareSectors(library.cards.last);
    expect(fourK[31].firstBlock, 124);
    expect(fourK[31].lastBlock, 127);
    expect(fourK[32].firstBlock, 128);
    expect(fourK[32].lastBlock, 143);
    expect(fourK[39].firstBlock, 240);
    expect(fourK[39].lastBlock, 255);
  });

  test('rejects sector parsing for non-Classic and malformed dumps', () async {
    final root = await Directory.systemTemp.createTemp('tagentra-card-test-');
    addTearDown(() => root.delete(recursive: true));
    final library = CardLibrary(root);
    await library.open();
    final nonClassic = await library.save(
      name: 'NTAG',
      protocol: CardProtocol.mfuNtag,
      cardType: 'NTAG',
      uid: '01',
      bytes: Uint8List(1024),
      format: 'bin',
      rrgRevision: 'test',
    );
    final malformed = await library.save(
      name: 'Malformed Classic',
      protocol: CardProtocol.mifareClassic,
      cardType: 'MIFARE Classic',
      uid: '02',
      bytes: Uint8List(1000),
      format: 'bin',
      rrgRevision: 'test',
    );

    expect(
      library.readMifareSectors(nonClassic),
      throwsA(isA<FormatException>()),
    );
    expect(
      library.readMifareSectors(malformed),
      throwsA(isA<FormatException>()),
    );
  });
}

TagentraPm3Artifact _artifact(File file) {
  final stat = file.statSync();
  return TagentraPm3Artifact(
    id: '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
    path: file.path,
    name: file.uri.pathSegments.last,
    size: stat.size,
    modifiedAt: stat.modified.toUtc(),
  );
}
