import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fast_chat/main.dart';

void main() {
  testWidgets('Fast Chat home renders', (WidgetTester tester) async {
    await tester.pumpWidget(const FastChatApp());

    expect(find.text('Fast Chat'), findsOneWidget);
    expect(find.text('局域网房间'), findsOneWidget);
    expect(find.text('选择一个聊天室'), findsOneWidget);
    expect(find.text('允许作为中继'), findsOneWidget);
  });

  testWidgets('Fast Chat compact layout renders', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const FastChatApp());

    expect(find.text('Fast Chat'), findsOneWidget);
    expect(find.text('局域网房间'), findsOneWidget);
    expect(find.text('选择一个聊天室'), findsOneWidget);
  });

  testWidgets('settings dialog closes with escape', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const FastChatApp());

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
