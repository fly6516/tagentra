import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

enum CardProtocol { mifareClassic, mfuNtag, iso15693, lf, unknown }

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
    tags: List<String>.from(json['tags']! as List),
    notes: json['notes']! as String,
    dataFormat: json['dataFormat']! as String,
    dataFile: json['dataFile']! as String,
    rrgRevision: json['rrgRevision']! as String,
    originalFile: json['originalFile'] as String?,
  );

  StoredCard copyWith({String? name, List<String>? tags, String? notes}) =>
      StoredCard(
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
      );
}

final class CardLibrary {
  CardLibrary(this.root);
  final Directory root;
  late final Directory _data = Directory(
    '${root.path}${Platform.pathSeparator}data',
  );
  late final Directory _originals = Directory(
    '${root.path}${Platform.pathSeparator}originals',
  );
  late final File _index = File(
    '${root.path}${Platform.pathSeparator}index.json',
  );
  final List<StoredCard> _cards = [];

  List<StoredCard> get cards => List.unmodifiable(_cards);

  Future<void> open() async {
    await _data.create(recursive: true);
    await _originals.create(recursive: true);
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

  Future<Uint8List> readData(StoredCard card) =>
      File('${_data.path}${Platform.pathSeparator}${card.dataFile}')
          .readAsBytes();

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
    return File('${_data.path}${Platform.pathSeparator}${card.dataFile}')
        .copy(target.path);
  }

  Future<void> _writeIndex() async {
    final text = const JsonEncoder.withIndent('  ')
        .convert(_cards.map((card) => card.toJson()).toList());
    final temporary = File('${_index.path}.tmp');
    await temporary.writeAsString('$text\n', flush: true);
    await temporary.rename(_index.path);
  }

  Future<void> _atomicBytes(File target, List<int> bytes) async {
    final temporary = File('${target.path}.tmp');
    await temporary.writeAsBytes(bytes, flush: true);
    await temporary.rename(target.path);
  }

  String _safeExtension(String value) {
    final extension = value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    const allowed = {'bin', 'dump', 'mfd', 'json', 'eml'};
    return allowed.contains(extension) ? extension : 'bin';
  }
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
