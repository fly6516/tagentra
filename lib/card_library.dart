import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:tagentra_pm3/tagentra_pm3.dart';

enum CardProtocol { mifareClassic, mfuNtag, iso15693, lf, unknown }

enum CardUnlockStatus { dumpOnly, complete }

enum CardArtifactKind { dumpBin, dumpJson, keyBin }

final class MifareSectorKeys {
  const MifareSectorKeys({
    required this.sector,
    required this.keyA,
    required this.keyB,
  });
  final int sector;
  final String keyA;
  final String keyB;

  Map<String, Object?> toJson() => {
    'sector': sector,
    'keyA': keyA,
    'keyB': keyB,
  };

  factory MifareSectorKeys.fromJson(Map<String, Object?> json) =>
      MifareSectorKeys(
        sector: json['sector']! as int,
        keyA: json['keyA']! as String,
        keyB: json['keyB']! as String,
      );
}

final class MifareBlockData {
  MifareBlockData({
    required this.block,
    required this.offset,
    required Iterable<int> bytes,
    required this.isSectorTrailer,
  }) : bytes = List<int>.unmodifiable(bytes);

  final int block;
  final int offset;
  final List<int> bytes;
  final bool isSectorTrailer;
}

final class MifareSectorData {
  MifareSectorData({
    required this.sector,
    required Iterable<MifareBlockData> blocks,
  }) : blocks = List<MifareBlockData>.unmodifiable(blocks);

  final int sector;
  final List<MifareBlockData> blocks;
  int get firstBlock => blocks.first.block;
  int get lastBlock => blocks.last.block;
  int get byteLength =>
      blocks.fold(0, (total, block) => total + block.bytes.length);
}

final class StoredCardArtifact {
  const StoredCardArtifact({
    required this.sourceId,
    required this.kind,
    required this.file,
    required this.originalName,
    this.sourcePath,
  });
  final String sourceId;
  final CardArtifactKind kind;
  final String file;
  final String originalName;
  final String? sourcePath;

  Map<String, Object?> toJson() => {
    'sourceId': sourceId,
    'kind': kind.name,
    'file': file,
    'originalName': originalName,
    'sourcePath': sourcePath,
  };

  factory StoredCardArtifact.fromJson(Map<String, Object?> json) =>
      StoredCardArtifact(
        sourceId: json['sourceId']! as String,
        kind: CardArtifactKind.values.firstWhere(
          (value) => value.name == json['kind'],
        ),
        file: json['file']! as String,
        originalName: json['originalName']! as String,
        sourcePath: json['sourcePath'] as String?,
      );
}

final class StoredCard {
  const StoredCard({
    required this.id,
    required this.name,
    required this.protocol,
    required this.cardType,
    required this.uid,
    required this.source,
    required this.createdAt,
    required this.updatedAt,
    required this.tags,
    required this.notes,
    required this.dataFormat,
    required this.dataFile,
    required this.rrgRevision,
    required this.originalFile,
    this.artifactGroup,
    this.sourceArtifactIds = const [],
    this.artifacts = const [],
    this.unlockStatus = CardUnlockStatus.dumpOnly,
    this.sectorKeys = const [],
  });

  final String id;
  final String name;
  final CardProtocol protocol;
  final String cardType;
  final String uid;
  final String source;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<String> tags;
  final String notes;
  final String dataFormat;
  final String dataFile;
  final String rrgRevision;
  final String? originalFile;
  final String? artifactGroup;
  final List<String> sourceArtifactIds;
  final List<StoredCardArtifact> artifacts;
  final CardUnlockStatus unlockStatus;
  final List<MifareSectorKeys> sectorKeys;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'cardType': cardType,
    'uid': uid,
    'source': source,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'tags': tags,
    'notes': notes,
    'dataFormat': dataFormat,
    'dataFile': dataFile,
    'rrgRevision': rrgRevision,
    'originalFile': originalFile,
    'artifactGroup': artifactGroup,
    'sourceArtifactIds': sourceArtifactIds,
    'artifacts': artifacts.map((value) => value.toJson()).toList(),
    'unlockStatus': unlockStatus.name,
    'sectorKeys': sectorKeys.map((value) => value.toJson()).toList(),
  };

  factory StoredCard.fromJson(Map<String, Object?> json) => StoredCard(
    id: json['id']! as String,
    name: json['name']! as String,
    protocol: CardProtocol.values.firstWhere(
      (value) => value.name == json['protocol'],
      orElse: () => CardProtocol.unknown,
    ),
    cardType: json['cardType']! as String,
    uid: json['uid']! as String,
    source: json['source']! as String,
    createdAt: DateTime.parse(json['createdAt']! as String),
    updatedAt: DateTime.parse(json['updatedAt']! as String),
    tags: List<String>.from((json['tags'] as List?) ?? const []),
    notes: json['notes'] as String? ?? '',
    dataFormat: json['dataFormat']! as String,
    dataFile: json['dataFile']! as String,
    rrgRevision: json['rrgRevision'] as String? ?? 'unknown',
    originalFile: json['originalFile'] as String?,
    artifactGroup: json['artifactGroup'] as String?,
    sourceArtifactIds: List<String>.from(
      (json['sourceArtifactIds'] as List?) ?? const [],
    ),
    artifacts: ((json['artifacts'] as List?) ?? const [])
        .map(
          (value) => StoredCardArtifact.fromJson(
            Map<String, Object?>.from(value as Map),
          ),
        )
        .toList(growable: false),
    unlockStatus: CardUnlockStatus.values.firstWhere(
      (value) => value.name == json['unlockStatus'],
      orElse: () => CardUnlockStatus.dumpOnly,
    ),
    sectorKeys: ((json['sectorKeys'] as List?) ?? const [])
        .map(
          (value) => MifareSectorKeys.fromJson(
            Map<String, Object?>.from(value as Map),
          ),
        )
        .toList(growable: false),
  );

  StoredCard copyWith({
    String? name,
    List<String>? tags,
    String? notes,
    List<String>? sourceArtifactIds,
    List<StoredCardArtifact>? artifacts,
    CardUnlockStatus? unlockStatus,
    List<MifareSectorKeys>? sectorKeys,
  }) => StoredCard(
    id: id,
    name: name ?? this.name,
    protocol: protocol,
    cardType: cardType,
    uid: uid,
    source: source,
    createdAt: createdAt,
    updatedAt: DateTime.now().toUtc(),
    tags: List.unmodifiable(tags ?? this.tags),
    notes: notes ?? this.notes,
    dataFormat: dataFormat,
    dataFile: dataFile,
    rrgRevision: rrgRevision,
    originalFile: originalFile,
    artifactGroup: artifactGroup,
    sourceArtifactIds: List.unmodifiable(
      sourceArtifactIds ?? this.sourceArtifactIds,
    ),
    artifacts: List.unmodifiable(artifacts ?? this.artifacts),
    unlockStatus: unlockStatus ?? this.unlockStatus,
    sectorKeys: List.unmodifiable(sectorKeys ?? this.sectorKeys),
  );
}

final class ArtifactImportResult {
  const ArtifactImportResult({
    required this.imported,
    required this.updated,
    required this.keysWithoutDump,
  });
  final List<StoredCard> imported;
  final List<StoredCard> updated;
  final List<String> keysWithoutDump;
  bool get changed => imported.isNotEmpty || updated.isNotEmpty;
}

final class CardLibrary {
  CardLibrary(this.root, {this.artifactSourceRoot});
  final Directory root;
  final Directory? artifactSourceRoot;
  late final Directory _data = Directory(
    '${root.path}${Platform.pathSeparator}data',
  );
  late final Directory _originals = Directory(
    '${root.path}${Platform.pathSeparator}originals',
  );
  late final Directory _artifacts = Directory(
    '${root.path}${Platform.pathSeparator}artifacts',
  );
  late final File _index = File(
    '${root.path}${Platform.pathSeparator}index.json',
  );
  final List<StoredCard> _cards = [];

  List<StoredCard> get cards => List.unmodifiable(_cards);

  Future<void> open() async {
    await _data.create(recursive: true);
    await _originals.create(recursive: true);
    await _artifacts.create(recursive: true);
    if (!_index.existsSync()) return;
    final decoded = jsonDecode(await _index.readAsString()) as List;
    _cards
      ..clear()
      ..addAll(
        decoded.map(
          (value) =>
              StoredCard.fromJson(Map<String, Object?>.from(value as Map)),
        ),
      );
  }

  Future<StoredCard> save({
    required String name,
    required CardProtocol protocol,
    required String cardType,
    required String uid,
    required Uint8List bytes,
    required String format,
    required String rrgRevision,
    String source = 'device',
    List<String> tags = const [],
    String notes = '',
    Uint8List? originalBytes,
    String? originalExtension,
  }) async {
    final now = DateTime.now().toUtc();
    final id = '${now.microsecondsSinceEpoch}-${_cards.length}';
    final dataName = '$id.bin';
    await _atomicBytes(
      File('${_data.path}${Platform.pathSeparator}$dataName'),
      bytes,
    );
    String? originalName;
    if (originalBytes != null) {
      final extension = _safeExtension(originalExtension ?? format);
      originalName = '$id.$extension';
      await _atomicBytes(
        File('${_originals.path}${Platform.pathSeparator}$originalName'),
        originalBytes,
      );
    }
    final card = StoredCard(
      id: id,
      name: name,
      protocol: protocol,
      cardType: cardType,
      uid: uid,
      source: source,
      createdAt: now,
      updatedAt: now,
      tags: List.unmodifiable(tags),
      notes: notes,
      dataFormat: format,
      dataFile: dataName,
      rrgRevision: rrgRevision,
      originalFile: originalName,
    );
    _cards.add(card);
    await _writeIndex();
    return card;
  }

  Future<ArtifactImportResult> importPm3Artifacts(
    Iterable<TagentraPm3Artifact> input, {
    required String rrgRevision,
  }) async {
    final groups = <String, _MifareArtifactGroup>{};
    for (final artifact in input) {
      final parsed = _parseMifareArtifact(artifact);
      if (parsed == null) continue;
      groups
          .putIfAbsent(
            parsed.group,
            () => _MifareArtifactGroup(uid: parsed.uid, group: parsed.group),
          )
          .add(parsed.kind, artifact);
    }

    final imported = <StoredCard>[];
    final updated = <StoredCard>[];
    final keysWithoutDump = <String>[];
    for (final group in groups.values) {
      final dump = group.dumpBin;
      if (dump == null) {
        final key = group.keyBin;
        if (key != null &&
            !_cards.any((card) => card.sourceArtifactIds.contains(key.id))) {
          keysWithoutDump.add(group.uid);
        }
        continue;
      }
      final dumpBytes = await File(dump.path).readAsBytes();
      final capacity = _mifareCapacities[dumpBytes.length];
      if (capacity == null) continue;
      final sourceIds = group.entries
          .map((entry) => entry.value.id)
          .toList(growable: false);
      final existingIndex = _cards.indexWhere(
        (card) => card.artifactGroup == group.group,
      );
      if (existingIndex >= 0 &&
          sourceIds.length == _cards[existingIndex].sourceArtifactIds.length &&
          sourceIds.every(_cards[existingIndex].sourceArtifactIds.contains)) {
        continue;
      }

      final id = existingIndex >= 0
          ? _cards[existingIndex].id
          : '${DateTime.now().toUtc().microsecondsSinceEpoch}-${_cards.length}';
      final artifacts = await _copyGroupArtifacts(id, group);
      final keys = group.keyBin == null
          ? const <MifareSectorKeys>[]
          : _parseKeys(
              await File(group.keyBin!.path).readAsBytes(),
              capacity.sectors,
            );
      final status = keys.isEmpty
          ? CardUnlockStatus.dumpOnly
          : CardUnlockStatus.complete;

      if (existingIndex >= 0) {
        final existing = _cards[existingIndex];
        await _atomicBytes(
          File('${_data.path}${Platform.pathSeparator}${existing.dataFile}'),
          dumpBytes,
        );
        final value = existing.copyWith(
          sourceArtifactIds: sourceIds,
          artifacts: artifacts,
          unlockStatus: status,
          sectorKeys: keys,
        );
        _cards[existingIndex] = value;
        updated.add(value);
      } else {
        final now = DateTime.now().toUtc();
        final dataName = '$id.bin';
        await _atomicBytes(
          File('${_data.path}${Platform.pathSeparator}$dataName'),
          dumpBytes,
        );
        final value = StoredCard(
          id: id,
          name: '${capacity.label} ${group.uid} ${_displayTime(now.toLocal())}',
          protocol: CardProtocol.mifareClassic,
          cardType: capacity.label,
          uid: group.uid,
          source: 'pm3',
          createdAt: now,
          updatedAt: now,
          tags: const [],
          notes: '',
          dataFormat: 'bin',
          dataFile: dataName,
          rrgRevision: rrgRevision,
          originalFile: null,
          artifactGroup: group.group,
          sourceArtifactIds: sourceIds,
          artifacts: artifacts,
          unlockStatus: status,
          sectorKeys: keys,
        );
        _cards.add(value);
        imported.add(value);
      }
    }
    if (imported.isNotEmpty || updated.isNotEmpty) await _writeIndex();
    return ArtifactImportResult(
      imported: imported,
      updated: updated,
      keysWithoutDump: keysWithoutDump,
    );
  }

  Future<List<StoredCardArtifact>> _copyGroupArtifacts(
    String cardId,
    _MifareArtifactGroup group,
  ) async {
    final directory = Directory(
      '${_artifacts.path}${Platform.pathSeparator}$cardId',
    );
    await directory.create(recursive: true);
    final result = <StoredCardArtifact>[];
    for (final entry in group.entries) {
      final safeName = entry.value.name.replaceAll(
        RegExp(r'[^A-Za-z0-9._-]'),
        '_',
      );
      final relative = '$cardId${Platform.pathSeparator}$safeName';
      await File(
        entry.value.path,
      ).copy('${_artifacts.path}${Platform.pathSeparator}$relative');
      result.add(
        StoredCardArtifact(
          sourceId: entry.value.id,
          kind: entry.key,
          file: relative,
          originalName: entry.value.name,
          sourcePath: entry.value.path,
        ),
      );
    }
    return result;
  }

  Iterable<StoredCard> search(String query) {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return cards;
    return _cards.where(
      (card) => [
        card.name,
        card.uid,
        card.cardType,
        card.notes,
        ...card.tags,
      ].any((value) => value.toLowerCase().contains(needle)),
    );
  }

  Future<StoredCard> updateMetadata(
    String id, {
    String? name,
    List<String>? tags,
    String? notes,
  }) async {
    final index = _cards.indexWhere((card) => card.id == id);
    if (index < 0) throw StateError('Card does not exist.');
    final updated = _cards[index].copyWith(
      name: name,
      tags: tags,
      notes: notes,
    );
    _cards[index] = updated;
    await _writeIndex();
    return updated;
  }

  Future<void> delete(String id) async {
    final index = _cards.indexWhere((card) => card.id == id);
    if (index < 0) throw StateError('Card does not exist.');
    final card = _cards.removeAt(index);
    await _deleteIfExists(
      File('${_data.path}${Platform.pathSeparator}${card.dataFile}'),
    );
    if (card.originalFile case final original?) {
      await _deleteIfExists(
        File('${_originals.path}${Platform.pathSeparator}$original'),
      );
    }
    for (final artifact in card.artifacts) {
      if (artifact.sourcePath case final source?) {
        await _deleteSourceArtifact(File(source));
      }
    }
    final directory = Directory(
      '${_artifacts.path}${Platform.pathSeparator}${card.id}',
    );
    if (await directory.exists()) await directory.delete(recursive: true);
    await _writeIndex();
  }

  List<File> filesForArtifacts(StoredCard card, Set<CardArtifactKind> kinds) =>
      card.artifacts
          .where((artifact) => kinds.contains(artifact.kind))
          .map(
            (artifact) => File(
              '${_artifacts.path}${Platform.pathSeparator}${artifact.file}',
            ),
          )
          .toList(growable: false);

  Future<StoredCard> importFile(
    File file, {
    required String name,
    required CardProtocol protocol,
    required String cardType,
    required String uid,
    required String rrgRevision,
    List<String> tags = const [],
    String notes = '',
  }) async {
    final extension = file.path.split('.').last.toLowerCase();
    const supported = {'bin', 'dump', 'mfd', 'json', 'eml'};
    if (!supported.contains(extension)) {
      throw const FormatException('Unsupported card file format.');
    }
    final original = await file.readAsBytes();
    return save(
      name: name,
      protocol: protocol,
      cardType: cardType,
      uid: uid,
      bytes: original,
      format: extension,
      rrgRevision: rrgRevision,
      source: 'import',
      tags: tags,
      notes: notes,
      originalBytes: original,
      originalExtension: extension,
    );
  }

  Future<Uint8List> readData(StoredCard card) => File(
    '${_data.path}${Platform.pathSeparator}${card.dataFile}',
  ).readAsBytes();

  Future<List<MifareSectorData>> readMifareSectors(StoredCard card) async {
    if (card.protocol != CardProtocol.mifareClassic) {
      throw const FormatException(
        'Only MIFARE Classic cards have sector data.',
      );
    }
    final bytes = await readData(card);
    final capacity = _mifareCapacities[bytes.length];
    if (capacity == null) {
      throw FormatException(
        'Unsupported MIFARE Classic dump length: ${bytes.length}.',
      );
    }

    var nextBlock = 0;
    final sectors = <MifareSectorData>[];
    for (var sector = 0; sector < capacity.sectors; sector++) {
      final blockCount = sector < 32 ? 4 : 16;
      final blocks = <MifareBlockData>[];
      for (var index = 0; index < blockCount; index++) {
        final block = nextBlock++;
        final offset = block * 16;
        blocks.add(
          MifareBlockData(
            block: block,
            offset: offset,
            bytes: bytes.sublist(offset, offset + 16),
            isSectorTrailer: index == blockCount - 1,
          ),
        );
      }
      sectors.add(MifareSectorData(sector: sector, blocks: blocks));
    }
    return List<MifareSectorData>.unmodifiable(sectors);
  }

  Future<List<int>> compare(StoredCard first, StoredCard second) async {
    final a = await readData(first), b = await readData(second);
    final changes = <int>[];
    for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
      if (i >= a.length || i >= b.length || a[i] != b[i]) changes.add(i);
    }
    return changes;
  }

  Future<File> export(StoredCard card, Directory destination) async {
    await destination.create(recursive: true);
    final safeName = card.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final target = File(
      '${destination.path}${Platform.pathSeparator}$safeName.${_safeExtension(card.dataFormat)}',
    );
    return File(
      '${_data.path}${Platform.pathSeparator}${card.dataFile}',
    ).copy(target.path);
  }

  Future<void> _writeIndex() async {
    final text = const JsonEncoder.withIndent(
      '  ',
    ).convert(_cards.map((card) => card.toJson()).toList());
    final temporary = File('${_index.path}.tmp');
    await temporary.writeAsString('$text\n', flush: true);
    await temporary.rename(_index.path);
  }

  Future<void> _atomicBytes(File target, List<int> bytes) async {
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }

  Future<void> _deleteIfExists(File file) async {
    if (await file.exists()) await file.delete();
  }

  Future<void> _deleteSourceArtifact(File file) async {
    final sourceRoot = artifactSourceRoot;
    if (sourceRoot == null || !await file.exists()) return;
    final rootPath = await sourceRoot.resolveSymbolicLinks();
    final filePath = await file.resolveSymbolicLinks();
    if (!filePath.startsWith('$rootPath${Platform.pathSeparator}')) return;
    await file.delete();
  }

  String _safeExtension(String value) {
    final extension = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const allowed = {'bin', 'dump', 'mfd', 'json', 'eml'};
    return allowed.contains(extension) ? extension : 'bin';
  }
}

final class _MifareCapacity {
  const _MifareCapacity(this.label, this.sectors);
  final String label;
  final int sectors;
}

const _mifareCapacities = <int, _MifareCapacity>{
  320: _MifareCapacity('MIFARE Classic Mini', 5),
  1024: _MifareCapacity('MIFARE Classic 1K', 16),
  2048: _MifareCapacity('MIFARE Classic 2K', 32),
  4096: _MifareCapacity('MIFARE Classic 4K', 40),
};

final class _ParsedMifareArtifact {
  const _ParsedMifareArtifact({
    required this.uid,
    required this.group,
    required this.kind,
  });
  final String uid;
  final String group;
  final CardArtifactKind kind;
}

_ParsedMifareArtifact? _parseMifareArtifact(TagentraPm3Artifact artifact) {
  final match = RegExp(
    r'^hf-mf-([0-9a-f]+)-(dump|key)(-[0-9]+)?\.(bin|json)$',
    caseSensitive: false,
  ).firstMatch(artifact.name);
  if (match == null) return null;
  final kind = switch ((
    match.group(2)!.toLowerCase(),
    match.group(4)!.toLowerCase(),
  )) {
    ('dump', 'bin') => CardArtifactKind.dumpBin,
    ('dump', 'json') => CardArtifactKind.dumpJson,
    ('key', 'bin') => CardArtifactKind.keyBin,
    _ => null,
  };
  if (kind == null) return null;
  final uid = match.group(1)!.toUpperCase();
  return _ParsedMifareArtifact(
    uid: uid,
    group: '$uid${match.group(3) ?? ''}',
    kind: kind,
  );
}

final class _MifareArtifactGroup {
  _MifareArtifactGroup({required this.uid, required this.group});
  final String uid;
  final String group;
  final Map<CardArtifactKind, TagentraPm3Artifact> _entries = {};
  TagentraPm3Artifact? get dumpBin => _entries[CardArtifactKind.dumpBin];
  TagentraPm3Artifact? get keyBin => _entries[CardArtifactKind.keyBin];
  Iterable<MapEntry<CardArtifactKind, TagentraPm3Artifact>> get entries =>
      _entries.entries;

  void add(CardArtifactKind kind, TagentraPm3Artifact artifact) {
    final current = _entries[kind];
    if (current == null || artifact.modifiedAt.isAfter(current.modifiedAt)) {
      _entries[kind] = artifact;
    }
  }
}

List<MifareSectorKeys> _parseKeys(Uint8List bytes, int sectors) {
  if (bytes.length != sectors * 12) return const [];
  String keyAt(int offset) => bytes
      .sublist(offset, offset + 6)
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
  return List.generate(
    sectors,
    (sector) => MifareSectorKeys(
      sector: sector,
      keyA: keyAt(sector * 6),
      keyB: keyAt((sectors + sector) * 6),
    ),
    growable: false,
  );
}

String _displayTime(DateTime value) {
  String two(int number) => number.toString().padLeft(2, '0');
  return '${value.year}-${two(value.month)}-${two(value.day)} '
      '${two(value.hour)}:${two(value.minute)}';
}

final class SafeWriteRequest {
  const SafeWriteRequest({
    required this.protocol,
    required this.expectedBytes,
    required this.payload,
    required this.targetDescription,
  });
  final CardProtocol protocol;
  final int expectedBytes;
  final Uint8List payload;
  final String targetDescription;

  void validate() {
    if (expectedBytes <= 0 || payload.length != expectedBytes) {
      throw StateError('Card capacity does not match the write payload.');
    }
    if (protocol == CardProtocol.unknown) {
      throw StateError('Unknown cards cannot be written.');
    }
  }
}

final class SafeWriteGuard {
  const SafeWriteGuard();

  Future<void> run({
    required SafeWriteRequest request,
    required Future<void> Function() backup,
    required Future<bool> Function(SafeWriteRequest request) confirm,
    required Future<void> Function() write,
    required Future<bool> Function() verify,
  }) async {
    request.validate();
    await backup();
    if (!await confirm(request)) throw StateError('Write was not confirmed.');
    await write();
    if (!await verify()) throw StateError('Write-back verification failed.');
  }
}
