import 'dart:async';

import 'package:flutter/services.dart';

enum TagentraDeviceMode { unknown, pm3, chameleon }

final class TagentraPm3Artifact {
  const TagentraPm3Artifact({
    required this.id,
    required this.path,
    required this.name,
    required this.size,
    required this.modifiedAt,
  });

  final String id;
  final String path;
  final String name;
  final int size;
  final DateTime modifiedAt;

  factory TagentraPm3Artifact.fromMap(Object? value) {
    final map = Map<String, Object?>.from(value! as Map);
    return TagentraPm3Artifact(
      id: map['id']! as String,
      path: map['path']! as String,
      name: map['name']! as String,
      size: map['size']! as int,
      modifiedAt: DateTime.parse(map['modifiedAt']! as String).toUtc(),
    );
  }
}

final class TagentraPm3CommandResult {
  const TagentraPm3CommandResult({
    required this.exitCode,
    required this.rrgRevision,
    required this.artifacts,
  });

  final int exitCode;
  final String rrgRevision;
  final List<TagentraPm3Artifact> artifacts;

  factory TagentraPm3CommandResult.fromMap(Object? value) {
    final map = Map<String, Object?>.from(value! as Map);
    return TagentraPm3CommandResult(
      exitCode: map['exitCode']! as int,
      rrgRevision: map['rrgRevision']! as String,
      artifacts: List<Object?>.from(
        map['artifacts']! as List,
      ).map(TagentraPm3Artifact.fromMap).toList(growable: false),
    );
  }
}

final class TagentraPm3Event {
  const TagentraPm3Event(this.type, this.payload);
  final String type;
  final Map<String, Object?> payload;

  factory TagentraPm3Event.fromMap(Object? value) {
    final map = Map<String, Object?>.from(value! as Map);
    return TagentraPm3Event(
      map.remove('type')! as String,
      Map<String, Object?>.unmodifiable(map),
    );
  }
}

final class TagentraPm3 {
  TagentraPm3({MethodChannel? methods, EventChannel? events})
    : _methods = methods ?? const MethodChannel('org.tagentra/pm3'),
      _events = events ?? const EventChannel('org.tagentra/pm3_events');

  final MethodChannel _methods;
  final EventChannel _events;

  Stream<TagentraPm3Event> get events =>
      _events.receiveBroadcastStream().map(TagentraPm3Event.fromMap);

  Future<void> startScan({Duration timeout = const Duration(seconds: 12)}) =>
      _methods.invokeMethod('startScan', {'timeoutMs': timeout.inMilliseconds});
  Future<void> stopScan() => _methods.invokeMethod('stopScan');
  Future<void> connect(String id) =>
      _methods.invokeMethod('connect', {'id': id});
  Future<void> reconnect() => _methods.invokeMethod('reconnect');
  Future<void> disconnect() => _methods.invokeMethod('disconnect');
  Future<Map<String, Object?>> status() async => Map<String, Object?>.from(
    (await _methods.invokeMethod<Object?>('status'))! as Map,
  );
  Future<TagentraDeviceMode> detectMode() async {
    final value = await _methods.invokeMethod<String>('detectMode');
    return TagentraDeviceMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => TagentraDeviceMode.unknown,
    );
  }

  Future<void> switchToPm3() => _methods.invokeMethod('switchToPm3');
  Future<void> switchToChameleon() =>
      _methods.invokeMethod('switchToChameleon');
  Future<TagentraPm3CommandResult> execute(String command) => _methods
      .invokeMethod<Object?>('execute', {'command': command})
      .then(TagentraPm3CommandResult.fromMap);
  Future<List<TagentraPm3Artifact>> listArtifacts() async => List<Object?>.from(
    (await _methods.invokeMethod<Object?>('listArtifacts'))! as List,
  ).map(TagentraPm3Artifact.fromMap).toList(growable: false);
  Future<void> shareArtifacts(Iterable<String> paths) => _methods.invokeMethod(
    'shareArtifacts',
    {'paths': paths.toList(growable: false)},
  );
  Future<void> cancel() => _methods.invokeMethod('cancel');
  Future<String> exportDiagnostics() =>
      _methods.invokeMethod<String>('exportDiagnostics').then((v) => v!);
  Future<String> applicationSupportDirectory() => _methods
      .invokeMethod<String>('applicationSupportDirectory')
      .then((v) => v!);
}
