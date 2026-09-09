import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tagentra/card_library.dart';
import 'package:tagentra/main.dart';
import 'package:tagentra_pm3/tagentra_pm3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('test/methods');
  const events = EventChannel('test/events');
  final methodCalls = <MethodCall>[];
  Object? methodError;
  String? clipboardText;
  late Directory supportDirectory;
  var artifactMaps = <Map<String, Object?>>[];

  setUp(() async {
    methodCalls.clear();
    methodError = null;
    clipboardText = null;
    artifactMaps = [];
    supportDirectory = await Directory.systemTemp.createTemp(
      'tagentra-widget-test-',
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (call) async {
      methodCalls.add(call);
      if (methodError case final error?) throw error;
      if (call.method == 'applicationSupportDirectory') {
        return supportDirectory.path;
      }
      if (call.method == 'listArtifacts') return artifactMaps;
      if (call.method == 'execute') {
        return <String, Object?>{
          'exitCode': 0,
          'rrgRevision': 'aaacc75',
          'artifacts': artifactMaps,
        };
      }
      return null;
    });
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText =
            (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name, events.codec),
      (_) async => null,
    );
  });
  tearDown(() async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    messenger.setMockMethodCallHandler(
      MethodChannel(events.name, events.codec),
      null,
    );
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  Future<void> emitEvent(
    WidgetTester tester,
    Map<String, Object?> event,
  ) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          events.name,
          events.codec.encodeSuccessEnvelope(event),
          (_) {},
        );
    await tester.pump();
  }

  Future<void> pumpIoUntil(
    WidgetTester tester,
    bool Function() condition,
  ) async {
    for (var attempt = 0; attempt < 50 && !condition(); attempt++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    expect(condition(), isTrue);
    for (var drain = 0; drain < 10; drain++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  testWidgets('shows the four primary work areas', (tester) async {
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    expect(find.text('Tagentra'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('工作台'), findsOneWidget);
    expect(find.text('卡库'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
  });

  testWidgets('offers PM3 switching when the connected device is Chameleon', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    await tester.tap(find.text('工作台'));
    await tester.pump();
    await emitEvent(tester, const {
      'type': 'connection',
      'state': 'ready',
      'mode': 'chameleon',
    });

    expect(find.text('变色龙模式'), findsOneWidget);
    expect(find.text('切换到 PM3'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('切换到 PM3'));
    await tester.pump();
    expect(
      methodCalls.where((call) => call.method == 'switchToPm3'),
      hasLength(1),
    );
  });

  testWidgets('mode selector requests switching back to Chameleon', (
    tester,
  ) async {
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    await emitEvent(tester, const {
      'type': 'connection',
      'state': 'ready',
      'mode': 'pm3',
    });

    await tester.tap(find.text('变色龙'));
    await tester.pump();

    expect(
      methodCalls.where((call) => call.method == 'switchToChameleon'),
      hasLength(1),
    );
  });

  testWidgets('card inspection fills the command without executing it', (
    tester,
  ) async {
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    await tester.tap(find.text('工作台'));
    await tester.pump();
    await emitEvent(tester, const {
      'type': 'connection',
      'state': 'ready',
      'mode': 'pm3',
    });

    await tester.tap(find.text('读取卡片属性'));
    await tester.pump();

    expect(find.text('hf 14a info'), findsOneWidget);
    expect(methodCalls.where((call) => call.method == 'execute'), isEmpty);
  });

  testWidgets('autopwn shortcut fills the command without executing it', (
    tester,
  ) async {
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    await tester.tap(find.text('工作台'));
    await tester.pump();
    await emitEvent(tester, const {
      'type': 'connection',
      'state': 'ready',
      'mode': 'pm3',
    });

    await tester.tap(find.byKey(const Key('autopwn-command')));
    await tester.pump();

    expect(find.text('hf mf autopwn'), findsOneWidget);
    expect(methodCalls.where((call) => call.method == 'execute'), isEmpty);
  });

  testWidgets('console output is selectable across log lines', (tester) async {
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    await tester.tap(find.text('工作台'));
    await tester.pump();
    await emitEvent(tester, const {'type': 'log', 'message': 'first line'});
    await emitEvent(tester, const {'type': 'log', 'message': 'second line'});

    final output = tester.widget<SelectableText>(
      find.byKey(const Key('console-output')),
    );
    expect(output.data, 'first line\nsecond line');
    expect(find.text('first line'), findsNothing);
    expect(find.text('second line'), findsNothing);
  });

  testWidgets('command errors can be copied from the error dialog', (
    tester,
  ) async {
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
      ),
    );
    await tester.tap(find.text('工作台'));
    await tester.pump();
    await emitEvent(tester, const {
      'type': 'connection',
      'state': 'ready',
      'mode': 'pm3',
    });
    methodError = PlatformException(
      code: 'pm3_not_ready',
      message: 'pm3transport is not ready',
    );

    await tester.enterText(find.byType(TextField), 'hw version');
    await tester.tap(find.byTooltip('发送指令'));
    await tester.pumpAndSettle();

    expect(find.text('指令执行失败'), findsOneWidget);
    expect(find.byKey(const Key('error-message')), findsOneWidget);
    await tester.tap(find.byKey(const Key('copy-error')));
    await tester.pump();

    expect(
      clipboardText,
      'PlatformException(pm3_not_ready, pm3transport is not ready, null, null)',
    );
    expect(find.text('错误信息已复制'), findsOneWidget);
  });

  testWidgets('imports a completed PM3 command into the card library', (
    tester,
  ) async {
    final library = CardLibrary(Directory('${supportDirectory.path}/cards'));
    await tester.runAsync(library.open);
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
        cardLibrary: library,
      ),
    );
    await tester.pumpAndSettle();
    final dump = File('${supportDirectory.path}/hf-mf-01020304-dump.bin');
    await tester.runAsync(() => dump.writeAsBytes(List.filled(1024, 0)));
    artifactMaps = [_artifactMap(dump)];
    await tester.tap(find.text('工作台'));
    await emitEvent(tester, const {
      'type': 'connection',
      'state': 'ready',
      'mode': 'pm3',
    });
    await tester.enterText(find.byType(TextField), 'hf mf autopwn');
    await tester.tap(find.byTooltip('发送指令'));
    await pumpIoUntil(
      tester,
      () => File('${supportDirectory.path}/cards/index.json').existsSync(),
    );
    await tester.pumpAndSettle();
    expect(methodCalls.where((call) => call.method == 'execute'), hasLength(1));
    expect(
      File('${supportDirectory.path}/cards/index.json').existsSync(),
      isTrue,
    );
    await tester.tap(find.text('卡库'));
    await tester.pumpAndSettle();

    expect(find.textContaining('MIFARE Classic 1K 01020304'), findsOneWidget);
  });

  testWidgets('reveals, copies, edits, exports, and deletes card details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dump = File('${supportDirectory.path}/hf-mf-a1b2c3d4-dump.bin');
    final json = File('${supportDirectory.path}/hf-mf-a1b2c3d4-dump.json');
    final key = File('${supportDirectory.path}/hf-mf-a1b2c3d4-key.bin');
    late CardLibrary library;
    await tester.runAsync(() async {
      await dump.writeAsBytes(List.filled(1024, 0));
      await json.writeAsString('{}');
      await key.writeAsBytes([
        ...List.filled(16 * 6, 0xaa),
        ...List.filled(16 * 6, 0xbb),
      ]);
      library = CardLibrary(
        Directory('${supportDirectory.path}/cards'),
        artifactSourceRoot: supportDirectory,
      );
      await library.open();
      await library.importPm3Artifacts(
        [
          dump,
          json,
          key,
        ].map((file) => TagentraPm3Artifact.fromMap(_artifactMap(file))),
        rrgRevision: 'aaacc75',
      );
    });
    artifactMaps = [dump, json, key].map(_artifactMap).toList();
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
        cardLibrary: library,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('卡库'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('MIFARE Classic 1K A1B2C3D4'));
    await tester.pumpAndSettle();

    expect(find.text('密钥已隐藏'), findsOneWidget);
    expect(find.textContaining('AAAAAAAAAAAA'), findsNothing);
    await tester.tap(find.byKey(const Key('toggle-keys')));
    await tester.pump();
    expect(find.textContaining('AAAAAAAAAAAA'), findsWidgets);
    await tester.tap(find.byKey(const Key('copy-key-a-0')));
    await tester.pump();
    expect(clipboardText, 'AAAAAAAAAAAA');

    await tester.tap(find.byKey(const Key('edit-card')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('edit-card-name')),
      'Office card',
    );
    await tester.enterText(
      find.byKey(const Key('edit-card-tags')),
      'office, test',
    );
    await tester.enterText(
      find.byKey(const Key('edit-card-notes')),
      'verified',
    );
    await tester.tap(find.byKey(const Key('save-card-edit')));
    await pumpIoUntil(tester, () => library.cards.single.name == 'Office card');
    await tester.pumpAndSettle();
    expect(find.text('Office card'), findsOneWidget);
    expect(find.text('office'), findsOneWidget);

    await tester.tap(find.byKey(const Key('export-card')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('export-dumpJson')));
    await tester.tap(find.byKey(const Key('share-selected-artifacts')));
    await tester.pumpAndSettle();
    final share = methodCalls.lastWhere(
      (call) => call.method == 'shareArtifacts',
    );
    final sharedPaths = List<String>.from(
      (share.arguments as Map<Object?, Object?>)['paths']! as List,
    );
    expect(sharedPaths, hasLength(2));
    expect(sharedPaths.any((path) => path.endsWith('.json')), isFalse);

    await tester.tap(find.byKey(const Key('delete-card')));
    await tester.pumpAndSettle();
    expect(find.text('删除卡片？'), findsOneWidget);
    await tester.tap(find.byKey(const Key('confirm-delete-card')));
    await pumpIoUntil(
      tester,
      () => library.cards.isEmpty && find.text('卡库为空').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    expect(find.text('卡库为空'), findsOneWidget);
  });

  testWidgets('expands sector data and protects trailer keys', (tester) async {
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final dump = File('${supportDirectory.path}/hf-mf-11223344-dump.bin');
    final key = File('${supportDirectory.path}/hf-mf-11223344-key.bin');
    late CardLibrary library;
    await tester.runAsync(() async {
      final dumpBytes = List.generate(1024, (index) => index & 0xff);
      dumpBytes
        ..replaceRange(48, 54, List.filled(6, 0xcc))
        ..replaceRange(54, 58, const [0xff, 0x07, 0x80, 0x69])
        ..replaceRange(58, 64, List.filled(6, 0xdd));
      await dump.writeAsBytes(dumpBytes);
      await key.writeAsBytes([
        ...List.filled(16 * 6, 0xaa),
        ...List.filled(16 * 6, 0xbb),
      ]);
      library = CardLibrary(
        Directory('${supportDirectory.path}/cards'),
        artifactSourceRoot: supportDirectory,
      );
      await library.open();
      await library.importPm3Artifacts(
        [
          dump,
          key,
        ].map((file) => TagentraPm3Artifact.fromMap(_artifactMap(file))),
        rrgRevision: 'aaacc75',
      );
    });
    artifactMaps = [dump, key].map(_artifactMap).toList();
    await tester.pumpWidget(
      TagentraApp(
        client: TagentraPm3(methods: methods, events: events),
        cardLibrary: library,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('卡库'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('MIFARE Classic 1K 11223344'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('扇区数据'));
    await pumpIoUntil(
      tester,
      () => find.text('16 个扇区 · 64 个块 · 1024 字节').evaluate().isNotEmpty,
    );
    expect(find.text('16 个扇区 · 64 个块 · 1024 字节'), findsOneWidget);
    ExpansionPanelList panels() =>
        tester.widget<ExpansionPanelList>(find.byType(ExpansionPanelList));
    expect(panels().children.every((panel) => !panel.isExpanded), isTrue);

    await tester.ensureVisible(find.byKey(const Key('sector-header-0')));
    await tester.tap(find.byKey(const Key('sector-header-0')));
    await tester.pumpAndSettle();
    expect(panels().children.first.isExpanded, isTrue);
    expect(find.byKey(const Key('block-data-0')), findsOneWidget);
    expect(find.text('制造商块'), findsOneWidget);
    expect(find.text('扇区尾块'), findsOneWidget);
    expect(find.textContaining('-- -- -- -- -- -- FF 07'), findsOneWidget);
    expect(find.textContaining('CC CC CC CC CC CC FF 07'), findsNothing);

    final detailsScroll = find.byKey(const Key('card-details-scroll'));
    await tester.drag(detailsScroll, const Offset(0, 600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('toggle-keys')));
    await tester.tap(find.byKey(const Key('toggle-keys')));
    await tester.pumpAndSettle();
    await tester.drag(detailsScroll, const Offset(0, -1600));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('block-data-3')));
    expect(find.textContaining('CC CC CC CC CC CC FF 07'), findsOneWidget);

    await tester.drag(detailsScroll, const Offset(0, 500));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('toggle-all-sectors')));
    await tester.tap(find.byKey(const Key('toggle-all-sectors')));
    await tester.pumpAndSettle();
    expect(find.text('全部折叠'), findsOneWidget);
    expect(panels().children.every((panel) => panel.isExpanded), isTrue);

    await tester.tap(find.byKey(const Key('toggle-all-sectors')));
    await tester.pumpAndSettle();
    expect(find.text('全部展开'), findsOneWidget);
    expect(panels().children.every((panel) => !panel.isExpanded), isTrue);
  });
}

Map<String, Object?> _artifactMap(File file) {
  final stat = file.statSync();
  return {
    'id': '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}',
    'path': file.path,
    'name': file.uri.pathSegments.last,
    'size': stat.size,
    'modifiedAt': stat.modified.toUtc().toIso8601String(),
  };
}
