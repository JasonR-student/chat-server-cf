import 'package:flutter/material.dart';

import 'chat_controller.dart';

void main() {
  runApp(const ChatClientApp());
}

enum ChatMode { direct, group }

class ChatClientApp extends StatelessWidget {
  const ChatClientApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Jason Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF246BFD),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      home: const ChatPage(),
    );
  }
}

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final ChatController _chat = ChatController();
  final TextEditingController _serverController = TextEditingController(
    text: 'wss://server.jasonrhan.cn',
  );
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _targetController = TextEditingController();
  final TextEditingController _groupController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final GlobalKey<FormState> _connectionFormKey = GlobalKey<FormState>();
  ChatMode _chatMode = ChatMode.direct;

  @override
  void initState() {
    super.initState();
    _chat.addListener(_handleControllerChange);
  }

  void _handleControllerChange() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  void dispose() {
    _chat
      ..removeListener(_handleControllerChange)
      ..dispose();
    _serverController.dispose();
    _usernameController.dispose();
    _targetController.dispose();
    _groupController.dispose();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _toggleConnection() async {
    if (_chat.connectionState != ChatConnectionState.disconnected) {
      _chat.disconnect();
      return;
    }

    if (!(_connectionFormKey.currentState?.validate() ?? false)) return;

    try {
      await _chat.connect(
        serverUrl: _serverController.text,
        username: _usernameController.text,
      );
    } on ArgumentError catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message.toString())),
      );
    }
  }

  void _sendMessage() {
    final sent = _chatMode == ChatMode.direct
        ? _chat.sendMessage(
            target: _targetController.text,
            content: _messageController.text,
          )
        : _chat.sendGroupMessage(
            group: _groupController.text,
            content: _messageController.text,
          );

    if (sent) {
      _messageController.clear();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _chatMode == ChatMode.direct
              ? '请先连接，并填写目标用户和消息内容'
              : '请先连接、加入群聊并填写消息内容',
        ),
      ),
    );
  }

  void _toggleGroupMembership() {
    final group = _groupController.text.trim();
    final changed = _chat.isInGroup(group)
        ? _chat.leaveGroup(group)
        : _chat.joinGroup(group);

    if (!changed) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先完成连接和注册，并填写群聊名称')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerLowest,
      appBar: AppBar(
        title: const Text('Jason Chat'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: _StatusBadge(
              state: _chat.connectionState,
              label: _chat.statusText,
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: <Widget>[
                  _buildConnectionCard(),
                  const SizedBox(height: 12),
                  Expanded(child: _buildConversationCard()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConnectionCard() {
    final canEdit = _chat.connectionState == ChatConnectionState.disconnected;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _connectionFormKey,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final narrow = constraints.maxWidth < 650;
              final serverField = TextFormField(
                key: const Key('serverField'),
                controller: _serverController,
                enabled: canEdit,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  prefixIcon: Icon(Icons.cloud_outlined),
                ),
                validator: (String? value) {
                  final uri = Uri.tryParse(value?.trim() ?? '');
                  if (uri == null ||
                      uri.host.isEmpty ||
                      (uri.scheme != 'ws' && uri.scheme != 'wss')) {
                    return '请输入 ws:// 或 wss:// 地址';
                  }
                  return null;
                },
              );
              final usernameField = TextFormField(
                key: const Key('usernameField'),
                controller: _usernameController,
                enabled: canEdit,
                decoration: const InputDecoration(
                  labelText: '我的用户名',
                  prefixIcon: Icon(Icons.person_outline),
                ),
                validator: (String? value) =>
                    (value == null || value.trim().isEmpty) ? '请输入用户名' : null,
                onFieldSubmitted: (_) => _toggleConnection(),
              );
              final connectionButton = FilledButton.icon(
                key: const Key('connectionButton'),
                onPressed: _toggleConnection,
                icon: Icon(canEdit ? Icons.login : Icons.logout),
                label: Text(canEdit ? '连接并上线' : '断开'),
              );

              if (narrow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    serverField,
                    const SizedBox(height: 12),
                    usernameField,
                    const SizedBox(height: 12),
                    connectionButton,
                  ],
                );
              }

              return Row(
                children: <Widget>[
                  Expanded(flex: 3, child: serverField),
                  const SizedBox(width: 12),
                  Expanded(flex: 2, child: usernameField),
                  const SizedBox(width: 12),
                  connectionButton,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildConversationCard() {
    final selectedGroup = _groupController.text.trim();
    final groupJoined = _chat.isInGroup(selectedGroup);

    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          Expanded(
            child: _chat.events.isEmpty
                ? const _EmptyConversation()
                : ListView.builder(
                    key: const Key('messageList'),
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: _chat.events.length,
                    itemBuilder: (BuildContext context, int index) {
                      return _MessageBubble(event: _chat.events[index]);
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SegmentedButton<ChatMode>(
                  key: const Key('chatModeSelector'),
                  segments: const <ButtonSegment<ChatMode>>[
                    ButtonSegment<ChatMode>(
                      value: ChatMode.direct,
                      icon: Icon(Icons.person_outline),
                      label: Text('私聊'),
                    ),
                    ButtonSegment<ChatMode>(
                      value: ChatMode.group,
                      icon: Icon(Icons.groups_outlined),
                      label: Text('群聊'),
                    ),
                  ],
                  selected: <ChatMode>{_chatMode},
                  onSelectionChanged: (Set<ChatMode> selection) {
                    setState(() => _chatMode = selection.first);
                  },
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (
                    BuildContext context,
                    BoxConstraints constraints,
                  ) {
                    final narrow = constraints.maxWidth < 620;
                    final destinationField = TextField(
                      key: Key(
                        _chatMode == ChatMode.direct
                            ? 'targetField'
                            : 'groupField',
                      ),
                      controller: _chatMode == ChatMode.direct
                          ? _targetController
                          : _groupController,
                      enabled: _chat.isConnected,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText:
                            _chatMode == ChatMode.direct ? '目标用户' : '群聊名称',
                        prefixIcon: Icon(
                          _chatMode == ChatMode.direct
                              ? Icons.alternate_email
                              : Icons.groups_outlined,
                        ),
                      ),
                    );
                    final messageField = TextField(
                      key: const Key('messageField'),
                      controller: _messageController,
                      enabled: _chat.isConnected,
                      minLines: 1,
                      maxLines: 4,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                      decoration: const InputDecoration(
                        labelText: '消息内容',
                        prefixIcon: Icon(Icons.chat_bubble_outline),
                      ),
                    );
                    final groupButton = OutlinedButton.icon(
                      key: const Key('groupActionButton'),
                      onPressed: _chat.isRegistered && selectedGroup.isNotEmpty
                          ? _toggleGroupMembership
                          : null,
                      icon: Icon(
                        groupJoined ? Icons.group_remove : Icons.group_add,
                      ),
                      label: Text(groupJoined ? '退出群聊' : '加入群聊'),
                    );
                    final canSend = _chatMode == ChatMode.direct
                        ? _chat.isConnected
                        : _chat.isConnected && groupJoined;
                    final sendButton = FilledButton.icon(
                      key: const Key('sendButton'),
                      onPressed: canSend ? _sendMessage : null,
                      icon: const Icon(Icons.send),
                      label: const Text('发送'),
                    );

                    if (narrow) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          destinationField,
                          if (_chatMode == ChatMode.group) ...<Widget>[
                            const SizedBox(height: 12),
                            groupButton,
                          ],
                          const SizedBox(height: 12),
                          messageField,
                          const SizedBox(height: 12),
                          sendButton,
                        ],
                      );
                    }

                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        SizedBox(width: 190, child: destinationField),
                        if (_chatMode == ChatMode.group) ...<Widget>[
                          const SizedBox(width: 12),
                          groupButton,
                        ],
                        const SizedBox(width: 12),
                        Expanded(child: messageField),
                        const SizedBox(width: 12),
                        sendButton,
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.state, required this.label});

  final ChatConnectionState state;
  final String label;

  @override
  Widget build(BuildContext context) {
    final color = switch (state) {
      ChatConnectionState.connected => Colors.green,
      ChatConnectionState.connecting ||
      ChatConnectionState.reconnecting =>
        Colors.orange,
      ChatConnectionState.disconnected => Colors.grey,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 10, color: color),
          const SizedBox(width: 8),
          Text(label, softWrap: false),
        ],
      ),
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.forum_outlined, size: 56),
          SizedBox(height: 12),
          Text('连接服务器后，可以进行私聊或加入群聊'),
        ],
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({required this.event});

  final ChatEvent event;

  @override
  Widget build(BuildContext context) {
    final outgoing = event.kind == ChatEventKind.outgoing;
    final incoming = event.kind == ChatEventKind.incoming;
    final scheme = Theme.of(context).colorScheme;
    final background = switch (event.kind) {
      ChatEventKind.outgoing => scheme.primaryContainer,
      ChatEventKind.incoming => scheme.secondaryContainer,
      ChatEventKind.error => scheme.errorContainer,
      ChatEventKind.receipt => scheme.tertiaryContainer,
      ChatEventKind.system => scheme.surfaceContainerHigh,
    };

    return Align(
      alignment: outgoing
          ? Alignment.centerRight
          : incoming
              ? Alignment.centerLeft
              : Alignment.center,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 680),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment:
              outgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: <Widget>[
            Text(event.text),
            const SizedBox(height: 4),
            Text(
              _formatTime(event.timestamp),
              style: Theme.of(context).textTheme.labelSmall,
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
