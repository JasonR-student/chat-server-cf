import 'package:chat_flutter_client/chat_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('拒绝空用户名', () async {
    final controller = ChatController();
    addTearDown(controller.dispose);

    await expectLater(
      controller.connect(
        serverUrl: 'wss://server.jasonrhan.cn',
        username: '  ',
      ),
      throwsArgumentError,
    );
  });

  test('拒绝非 WebSocket 地址', () async {
    final controller = ChatController();
    addTearDown(controller.dispose);

    await expectLater(
      controller.connect(
        serverUrl: 'https://server.jasonrhan.cn',
        username: 'alice',
      ),
      throwsArgumentError,
    );
  });

  test('未连接时不能发送消息', () {
    final controller = ChatController();
    addTearDown(controller.dispose);

    final sent = controller.sendMessage(target: 'bob', content: '你好');

    expect(sent, isFalse);
    expect(controller.events, isEmpty);
  });

  test('未连接时不能加入群聊或发送群消息', () {
    final controller = ChatController();
    addTearDown(controller.dispose);

    expect(controller.joinGroup('研发群'), isFalse);
    expect(
      controller.sendGroupMessage(group: '研发群', content: '大家好'),
      isFalse,
    );
    expect(controller.joinedGroups, isEmpty);
  });
}
