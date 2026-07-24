import 'package:chat_flutter_client/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('显示连接和发送所需控件', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatClientApp());

    expect(find.text('Jason Chat'), findsOneWidget);
    expect(find.byKey(const Key('serverField')), findsOneWidget);
    expect(find.byKey(const Key('usernameField')), findsOneWidget);
    expect(find.byKey(const Key('targetField')), findsOneWidget);
    expect(find.byKey(const Key('messageField')), findsOneWidget);
    expect(find.byKey(const Key('sendButton')), findsOneWidget);
    expect(find.byKey(const Key('chatModeSelector')), findsOneWidget);
    expect(find.text('未连接'), findsOneWidget);
  });

  testWidgets('切换群聊模式后显示群聊控件', (WidgetTester tester) async {
    await tester.pumpWidget(const ChatClientApp());

    await tester.tap(find.text('群聊'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('groupField')), findsOneWidget);
    expect(find.byKey(const Key('groupActionButton')), findsOneWidget);
    expect(find.text('加入群聊'), findsOneWidget);
  });
}
