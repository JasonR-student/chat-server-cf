import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

enum ChatConnectionState {
  disconnected,
  connecting,
  connected,
  reconnecting,
}

enum ChatEventKind {
  incoming,
  outgoing,
  receipt,
  system,
  error,
}

class ChatEvent {
  const ChatEvent({
    required this.kind,
    required this.text,
    required this.timestamp,
  });

  final ChatEventKind kind;
  final String text;
  final DateTime timestamp;
}

typedef ChannelConnector = WebSocketChannel Function(Uri uri);

class ChatController extends ChangeNotifier {
  ChatController({ChannelConnector? connector})
      : _connector = connector ?? WebSocketChannel.connect;

  static const reconnectDelay = Duration(seconds: 3);
  static const heartbeatInterval = Duration(seconds: 30);

  final ChannelConnector _connector;
  final List<ChatEvent> _events = <ChatEvent>[];
  final Set<String> _desiredGroups = <String>{};
  final Set<String> _joinedGroups = <String>{};

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  Uri? _serverUri;
  String _username = '';
  int _session = 0;
  int _handledDisconnectSession = -1;
  bool _manualClose = true;
  bool _registered = false;
  ChatConnectionState _connectionState = ChatConnectionState.disconnected;

  List<ChatEvent> get events => List<ChatEvent>.unmodifiable(_events);
  ChatConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState == ChatConnectionState.connected;
  bool get isRegistered => _registered;
  String get username => _username;
  Set<String> get joinedGroups => Set<String>.unmodifiable(_joinedGroups);

  String get statusText {
    return switch (_connectionState) {
      ChatConnectionState.disconnected => '未连接',
      ChatConnectionState.connecting => '连接中',
      ChatConnectionState.connected => _registered ? '已上线' : '已连接',
      ChatConnectionState.reconnecting => '正在重连',
    };
  }

  Future<void> connect({
    required String serverUrl,
    required String username,
  }) async {
    final normalizedUsername = username.trim();
    if (normalizedUsername.isEmpty) {
      throw ArgumentError('用户名不能为空');
    }

    final uri = Uri.tryParse(serverUrl.trim());
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'ws' && uri.scheme != 'wss')) {
      throw ArgumentError('服务器地址必须以 ws:// 或 wss:// 开头');
    }

    _closeCurrentConnection(notify: false);
    _desiredGroups.clear();
    _joinedGroups.clear();
    _serverUri = uri;
    _username = normalizedUsername;
    _manualClose = false;
    await _openConnection(isReconnect: false);
  }

  void disconnect() {
    _manualClose = true;
    _desiredGroups.clear();
    _joinedGroups.clear();
    _closeCurrentConnection(notify: true);
    _addEvent(ChatEventKind.system, '已主动断开连接');
  }

  bool sendMessage({
    required String target,
    required String content,
  }) {
    final normalizedTarget = target.trim();
    final normalizedContent = content.trim();
    if (!isConnected || normalizedTarget.isEmpty || normalizedContent.isEmpty) {
      return false;
    }

    _sendPacket(<String, dynamic>{
      'type': 'message',
      'target': normalizedTarget,
      'content': normalizedContent,
    });
    _addEvent(
      ChatEventKind.outgoing,
      '你 → $normalizedTarget：$normalizedContent',
    );
    return true;
  }

  bool isInGroup(String group) => _joinedGroups.contains(group.trim());

  bool joinGroup(String group) {
    final normalizedGroup = group.trim();
    if (!isConnected || !_registered || normalizedGroup.isEmpty) {
      return false;
    }

    _desiredGroups.add(normalizedGroup);
    _sendPacket(<String, dynamic>{
      'type': 'join_group',
      'group': normalizedGroup,
    });
    return true;
  }

  bool leaveGroup(String group) {
    final normalizedGroup = group.trim();
    if (!isConnected ||
        normalizedGroup.isEmpty ||
        !_joinedGroups.contains(normalizedGroup)) {
      return false;
    }

    _desiredGroups.remove(normalizedGroup);
    _sendPacket(<String, dynamic>{
      'type': 'leave_group',
      'group': normalizedGroup,
    });
    return true;
  }

  bool sendGroupMessage({
    required String group,
    required String content,
  }) {
    final normalizedGroup = group.trim();
    final normalizedContent = content.trim();
    if (!isConnected ||
        !_joinedGroups.contains(normalizedGroup) ||
        normalizedContent.isEmpty) {
      return false;
    }

    _sendPacket(<String, dynamic>{
      'type': 'group_message',
      'group': normalizedGroup,
      'content': normalizedContent,
    });
    return true;
  }

  Future<void> _openConnection({required bool isReconnect}) async {
    final uri = _serverUri;
    if (uri == null || _manualClose) return;

    final currentSession = ++_session;
    _handledDisconnectSession = -1;
    _registered = false;
    _connectionState = isReconnect
        ? ChatConnectionState.reconnecting
        : ChatConnectionState.connecting;
    notifyListeners();

    try {
      final channel = _connector(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        (dynamic data) {
          if (currentSession == _session) {
            _handleServerMessage(data);
          }
        },
        onError: (Object error, StackTrace stackTrace) {
          if (currentSession != _session) return;
          _addEvent(ChatEventKind.error, '连接错误：$error');
          _handleDisconnect(currentSession);
        },
        onDone: () => _handleDisconnect(currentSession),
        cancelOnError: false,
      );

      await channel.ready;
      if (currentSession != _session || _manualClose) {
        await channel.sink.close(status.normalClosure);
        return;
      }

      _connectionState = ChatConnectionState.connected;
      _sendPacket(<String, dynamic>{
        'type': 'register',
        'username': _username,
      });
      _startHeartbeat();
      _addEvent(ChatEventKind.system, '已连接服务器，正在注册 $_username');
    } catch (error) {
      if (currentSession != _session || _manualClose) return;
      _addEvent(ChatEventKind.error, '无法连接服务器：$error');
      _handleDisconnect(currentSession);
    }
  }

  void _handleServerMessage(dynamic rawData) {
    Map<String, dynamic> packet;
    try {
      final decoded = jsonDecode(rawData.toString());
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('消息不是 JSON 对象');
      }
      packet = decoded;
    } catch (error) {
      _addEvent(ChatEventKind.error, '收到无法解析的服务器消息：$error');
      return;
    }

    switch (packet['type']) {
      case 'registered':
        _registered = true;
        _addEvent(
          ChatEventKind.system,
          '已注册为 ${packet['username'] ?? _username}',
        );
        for (final group in _desiredGroups) {
          _sendPacket(<String, dynamic>{
            'type': 'join_group',
            'group': group,
          });
        }
      case 'message':
        final offlineMark = packet['isOffline'] == true ? '（离线消息）' : '';
        _addEvent(
          ChatEventKind.incoming,
          '${packet['from'] ?? '未知用户'} → 你$offlineMark：'
          '${packet['content'] ?? ''}',
        );
      case 'receipt':
        final deliveryText =
            packet['status'] == 'DELIVERED' ? '已送达' : '已保存，等待对方上线';
        _addEvent(
          ChatEventKind.receipt,
          '发给 ${packet['target'] ?? '目标用户'} 的消息$deliveryText',
        );
      case 'error':
        _addEvent(
          ChatEventKind.error,
          '${packet['message'] ?? '服务器处理失败'}'
          '（${packet['code'] ?? 'UNKNOWN'}）',
        );
      case 'warning':
        _addEvent(
          ChatEventKind.system,
          '${packet['message'] ?? '部分服务暂时不可用'}',
        );
      case 'group_joined':
        final group = packet['group']?.toString() ?? '';
        if (group.isNotEmpty) {
          _desiredGroups.add(group);
          _joinedGroups.add(group);
          _addEvent(
            ChatEventKind.system,
            '已加入群聊 $group（${packet['memberCount'] ?? 1} 人在线）',
          );
        }
      case 'group_left':
        final group = packet['group']?.toString() ?? '';
        _desiredGroups.remove(group);
        _joinedGroups.remove(group);
        _addEvent(ChatEventKind.system, '已退出群聊 $group');
      case 'group_message':
        final group = packet['group']?.toString() ?? '未知群聊';
        final from = packet['from']?.toString() ?? '未知用户';
        final content = packet['content']?.toString() ?? '';
        _addEvent(
          from == _username ? ChatEventKind.outgoing : ChatEventKind.incoming,
          '[$group] $from：$content',
        );
      case 'group_presence':
        final actionText = packet['action'] == 'joined' ? '加入' : '退出';
        _addEvent(
          ChatEventKind.system,
          '${packet['username'] ?? '某位用户'}$actionText群聊 '
          '${packet['group'] ?? ''}（${packet['memberCount'] ?? 0} 人在线）',
        );
      case 'pong':
        break;
      default:
        _addEvent(ChatEventKind.error, '收到未知类型的服务器消息');
    }
  }

  void _handleDisconnect(int connectionSession) {
    if (connectionSession != _session ||
        _handledDisconnectSession == connectionSession) {
      return;
    }
    _handledDisconnectSession = connectionSession;
    _heartbeatTimer?.cancel();
    _registered = false;
    _joinedGroups.clear();

    if (_manualClose) {
      _connectionState = ChatConnectionState.disconnected;
      notifyListeners();
      return;
    }

    _connectionState = ChatConnectionState.reconnecting;
    _addEvent(
      ChatEventKind.system,
      '${reconnectDelay.inSeconds} 秒后重新连接',
    );
    notifyListeners();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(
      reconnectDelay,
      () => _openConnection(isReconnect: true),
    );
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(
      heartbeatInterval,
      (_) => _sendPacket(<String, dynamic>{'type': 'ping'}),
    );
  }

  void _sendPacket(Map<String, dynamic> packet) {
    _channel?.sink.add(jsonEncode(packet));
  }

  void _addEvent(ChatEventKind kind, String text) {
    _events.add(
      ChatEvent(kind: kind, text: text, timestamp: DateTime.now()),
    );
    notifyListeners();
  }

  void _closeCurrentConnection({required bool notify}) {
    ++_session;
    _handledDisconnectSession = -1;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close(status.normalClosure, '客户端主动断开');
    _subscription = null;
    _channel = null;
    _registered = false;
    _joinedGroups.clear();
    _connectionState = ChatConnectionState.disconnected;
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _manualClose = true;
    _closeCurrentConnection(notify: false);
    super.dispose();
  }
}
