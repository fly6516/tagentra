import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tagentra/main.dart';
import 'package:tagentra_pm3/tagentra_pm3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('test/methods');
  const events = EventChannel('test/events');

  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async => null),
  );
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null),
  );

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
}
