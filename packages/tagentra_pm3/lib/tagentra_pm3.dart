import 'dart:async';

import 'package:flutter/services.dart';

enum TagentraDeviceMode { unknown, pm3, chameleon }

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
  Future<int> execute(String command) => _methods
      .invokeMethod<int>('execute', {'command': command})
      .then((v) => v!);
  Future<void> cancel() => _methods.invokeMethod('cancel');
  Future<String> exportDiagnostics() =>
      _methods.invokeMethod<String>('exportDiagnostics').then((v) => v!);
  Future<String> applicationSupportDirectory() => _methods
      .invokeMethod<String>('applicationSupportDirectory')
      .then((v) => v!);
}
