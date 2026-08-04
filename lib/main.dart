import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'compat/compatibility.dart';
import 'network/network_service.dart';
import 'notifications/notification_service.dart';

void main(List<String> args) {
  Compatibility.initialize(args);
  runApp(const FastChatApp());
}

class SendMessageIntent extends Intent {
  const SendMessageIntent();
}

class InsertNewlineIntent extends Intent {
  const InsertNewlineIntent();
}

class NativeWindow {
  NativeWindow._();

  static const _channel = MethodChannel('fast_chat/window');

  static Future<void> setNotificationTopMost(bool enabled) async {
    if (!Compatibility.peSafe) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setNotificationTopMost', enabled);
    } catch (_) {}
  }
}

enum _RoomAction { pin, mute, delete }

class _InAppNotification {
  const _InAppNotification({
    required this.id,
    required this.roomName,
    required this.sender,
    required this.text,
  });

  final int id;
  final String roomName;
  final String sender;
  final String text;
}

class _RoomPrefs {
  const _RoomPrefs({
    this.pinned = false,
    this.muted = false,
    this.hidden = false,
  });

  final bool pinned;
  final bool muted;
  final bool hidden;

  _RoomPrefs copyWith({bool? pinned, bool? muted, bool? hidden}) {
    return _RoomPrefs(
      pinned: pinned ?? this.pinned,
      muted: muted ?? this.muted,
      hidden: hidden ?? this.hidden,
    );
  }

  Map<String, dynamic> toJson() => {
    'pinned': pinned,
    'muted': muted,
    'hidden': hidden,
  };

  static _RoomPrefs fromJson(Map<String, dynamic> json) => _RoomPrefs(
    pinned: json['pinned'] == true,
    muted: json['muted'] == true,
    hidden: json['hidden'] == true,
  );
}

class FastChatApp extends StatelessWidget {
  const FastChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Fast Chat',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff176b5b)),
        scaffoldBackgroundColor: const Color(0xfff4f7f6),
        useMaterial3: true,
        fontFamily: 'sans',
      ),
      home: const ChatHomePage(),
    );
  }
}

class ChatHomePage extends StatefulWidget {
  const ChatHomePage({super.key});

  @override
  State<ChatHomePage> createState() => _ChatHomePageState();
}

class _ChatHomePageState extends State<ChatHomePage> {
  static const _prefDisplayName = 'display_name';
  static const _prefOobeDone = 'oobe_done';
  static const _prefGlobalMuted = 'global_muted';
  static const _prefSavedRooms = 'saved_rooms';
  static const _prefRoomPrefs = 'room_prefs';
  static const _prefRoomMessages = 'room_messages';
  static const _lobbyRoomId = '__lobby__';

  final _network = ChatNetworkService();
  final _messageController = TextEditingController();
  final _roomController = TextEditingController();
  final _nameController = TextEditingController(text: '访客');
  final _messagesScrollController = ScrollController();
  final Map<String, List<ChatMessage>> _messagesByRoom = {
    _lobbyRoomId: [
      ChatMessage(
        sender: '系统',
        text: '欢迎使用 Fast Chat，正在扫描局域网聊天室。',
        system: true,
      ),
    ],
  };
  StreamSubscription? _roomsSub;
  StreamSubscription? _hostedRoomsSub;
  StreamSubscription? _joinedRoomsSub;
  StreamSubscription? _messagesSub;
  StreamSubscription? _transfersSub;
  List<DiscoveredRoom> _rooms = [];
  List<DiscoveredRoom> _hostedRooms = [];
  List<DiscoveredRoom> _joinedRooms = [];
  final Map<String, DiscoveredRoom> _savedJoinedRooms = {};
  final Map<String, _RoomPrefs> _roomPrefs = {};
  DiscoveredRoom? _activeRoom;
  bool _relayEnabled = true;
  bool _scanning = true;
  bool _globalMuted = false;
  String? _error;
  Timer? _scanTimer;
  final Map<String, FileTransferStatus> _transfers = {};
  final Map<String, Timer> _transferCleanupTimers = {};
  final List<_InAppNotification> _inAppNotifications = [];
  final Map<int, Timer> _inAppNotificationTimers = {};
  int _nextInAppNotificationId = 1;

  @override
  void initState() {
    super.initState();
    _roomsSub = _network.rooms.listen((rooms) {
      if (mounted) setState(() => _rooms = rooms);
    });
    _hostedRoomsSub = _network.hostedRooms.listen((rooms) {
      if (mounted) setState(() => _hostedRooms = rooms);
    });
    _joinedRoomsSub = _network.joinedRooms.listen((rooms) {
      if (mounted) setState(() => _joinedRooms = rooms);
    });
    _messagesSub = _network.messages.listen((message) {
      if (mounted) {
        _appendMessage(message);
      }
    });
    _transfersSub = _network.transfers.listen((status) {
      if (!mounted) return;
      _transferCleanupTimers.remove(status.transferId)?.cancel();
      setState(() {
        _transfers[status.transferId] = status;
      });
      if (status.done || status.failed) {
        _transferCleanupTimers[status.transferId] = Timer(
          const Duration(seconds: 2),
          () {
            if (!mounted) {
              return;
            }
            setState(() {
              _transfers.remove(status.transferId);
            });
            _transferCleanupTimers.remove(status.transferId);
          },
        );
      }
    });
    NotificationService.initialize();
    _loadPreferences();
    _network.startDiscovery();
    _scanTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _scanning = false);
      }
    });
  }

  @override
  void dispose() {
    _roomsSub?.cancel();
    _hostedRoomsSub?.cancel();
    _joinedRoomsSub?.cancel();
    _messagesSub?.cancel();
    _transfersSub?.cancel();
    _scanTimer?.cancel();
    for (final timer in _transferCleanupTimers.values) {
      timer.cancel();
    }
    _transferCleanupTimers.clear();
    for (final timer in _inAppNotificationTimers.values) {
      timer.cancel();
    }
    _inAppNotificationTimers.clear();
    _network.dispose();
    _messageController.dispose();
    _roomController.dispose();
    _nameController.dispose();
    _messagesScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    final savedName = prefs.getString(_prefDisplayName)?.trim();
    final globalMuted = prefs.getBool(_prefGlobalMuted) ?? false;
    final savedRooms = _decodeJsonList(prefs.getString(_prefSavedRooms));
    final roomPrefs = _decodeJsonMap(prefs.getString(_prefRoomPrefs));
    final roomMessages = _decodeJsonMap(prefs.getString(_prefRoomMessages));
    if (!mounted) {
      return;
    }
    setState(() {
      if (savedName != null && savedName.isNotEmpty) {
        _nameController.text = savedName;
      }
      _globalMuted = globalMuted;
      _savedJoinedRooms
        ..clear()
        ..addEntries(
          savedRooms.map((json) {
            final room = _roomFromJson(json);
            return MapEntry(room.id, room);
          }),
        );
      _roomPrefs
        ..clear()
        ..addEntries(
          roomPrefs.entries.map(
            (entry) => MapEntry(
              entry.key,
              _RoomPrefs.fromJson(Map<String, dynamic>.from(entry.value)),
            ),
          ),
        );
      for (final entry in roomMessages.entries) {
        final messages = (entry.value as List)
            .whereType<Map>()
            .map((json) => _messageFromJson(Map<String, dynamic>.from(json)))
            .toList();
        if (messages.isNotEmpty) {
          _messagesByRoom[entry.key] = messages;
        }
      }
    });
    if (prefs.getBool(_prefOobeDone) != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showOobeDialog();
        }
      });
    }
  }

  List<Map<String, dynamic>> _decodeJsonList(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return const [];
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! List) {
        return const [];
      }
      return decoded
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Map<String, dynamic> _decodeJsonMap(String? encoded) {
    if (encoded == null || encoded.isEmpty) {
      return const {};
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        return const {};
      }
      return Map<String, dynamic>.from(decoded);
    } catch (_) {
      return const {};
    }
  }

  Map<String, dynamic> _roomToJson(DiscoveredRoom room) => {
    'id': room.id,
    'name': room.name,
    'host': room.host,
    'address': room.address,
    'port': room.port,
    'peers': room.peers,
    'relay': room.relay,
  };

  DiscoveredRoom _roomFromJson(Map<String, dynamic> json) => DiscoveredRoom(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '房间',
    host: json['host']?.toString() ?? '已保存',
    address: json['address']?.toString() ?? '127.0.0.1',
    port: json['port'] is int
        ? json['port'] as int
        : int.tryParse(json['port']?.toString() ?? '') ?? 0,
    peers: json['peers'] is int
        ? json['peers'] as int
        : int.tryParse(json['peers']?.toString() ?? '') ?? 1,
    relay: json['relay'] != false,
  );

  Map<String, dynamic> _messageToJson(ChatMessage message) => {
    'sender': message.sender,
    'text': message.text,
    'system': message.system,
    'roomId': message.roomId,
    'fileName': message.fileName,
    'fileSize': message.fileSize,
  };

  ChatMessage _messageFromJson(Map<String, dynamic> json) => ChatMessage(
    sender: json['sender']?.toString() ?? '访客',
    text: json['text']?.toString() ?? '',
    system: json['system'] == true,
    roomId: json['roomId']?.toString(),
    fileName: json['fileName']?.toString(),
    fileSize: json['fileSize'] is int
        ? json['fileSize'] as int
        : int.tryParse(json['fileSize']?.toString() ?? ''),
  );

  Future<void> _saveSavedRooms() async {
    final prefs = await SharedPreferences.getInstance();
    final visibleRooms = _savedJoinedRooms.values
        .where((room) => _roomPrefs[room.id]?.hidden != true)
        .map(_roomToJson)
        .toList();
    await prefs.setString(_prefSavedRooms, jsonEncode(visibleRooms));
  }

  Future<void> _saveRoomPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefRoomPrefs,
      jsonEncode(_roomPrefs.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<void> _saveMessagesForRoom(String roomId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefRoomMessages, jsonEncode(_serializedMessages()));
  }

  Map<String, dynamic> _serializedMessages() {
    final result = <String, dynamic>{};
    for (final entry in _messagesByRoom.entries) {
      if (entry.key == _lobbyRoomId) {
        continue;
      }
      final messages = entry.value
          .where((message) => !message.system)
          .map(_messageToJson)
          .toList();
      if (messages.isNotEmpty) {
        result[entry.key] = messages;
      }
    }
    return result;
  }

  Future<void> _removeMessagesForRoom(String roomId) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = _decodeJsonMap(prefs.getString(_prefRoomMessages));
    existing.remove(roomId);
    await prefs.setString(_prefRoomMessages, jsonEncode(existing));
  }

  List<ChatMessage> _messagesForRoom(String roomId) {
    return _messagesByRoom[roomId] ??
        const [
          ChatMessage(
            sender: '系统',
            text: '欢迎使用 Fast Chat，正在扫描局域网聊天室。',
            system: true,
          ),
        ];
  }

  List<DiscoveredRoom> _orderedRooms(List<DiscoveredRoom> rooms) {
    final copy = [...rooms];
    copy.sort((a, b) {
      final ap = _roomPrefs[a.id]?.pinned == true;
      final bp = _roomPrefs[b.id]?.pinned == true;
      if (ap != bp) return ap ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return copy;
  }

  List<DiscoveredRoom> get _visibleSavedJoinedRooms => _savedJoinedRooms.values
      .where(
        (room) =>
            _roomPrefs[room.id]?.hidden != true &&
            !_hostedRooms.any((hosted) => hosted.id == room.id),
      )
      .toList();

  List<DiscoveredRoom> get _visibleDiscoveredRooms =>
      _rooms.where((room) => _roomPrefs[room.id]?.hidden != true).toList();

  DiscoveredRoom? _roomById(String roomId) {
    for (final room in [
      ..._hostedRooms,
      ..._joinedRooms,
      ..._savedJoinedRooms.values,
      ..._rooms,
    ]) {
      if (room.id == roomId) {
        return room;
      }
    }
    return null;
  }

  Future<void> _completeOobe() async {
    if (_nameController.text.trim().isEmpty) {
      _nameController.text = '访客';
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefDisplayName, _nameController.text.trim());
    await prefs.setBool(_prefOobeDone, true);
  }

  Future<void> _finishOobe(
    TextEditingController controller,
    NavigatorState navigator,
  ) async {
    _nameController.text = controller.text.trim();
    await _completeOobe();
    if (mounted && navigator.mounted) {
      navigator.pop();
    }
  }

  void _appendMessage(ChatMessage message) {
    final roomId = message.roomId ?? _activeRoom?.id ?? _lobbyRoomId;
    setState(() {
      _messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    });
    if (roomId != _lobbyRoomId) {
      unawaited(_saveMessagesForRoom(roomId));
    }
    final currentName = _nameController.text.trim();
    final messageRoom = _roomById(roomId);
    if (!message.system &&
        message.sender != currentName &&
        messageRoom != null &&
        !_globalMuted &&
        _roomPrefs[roomId]?.muted != true) {
      final text = message.hasFile ? '发送了文件：${message.fileName}' : message.text;
      _showNotification(
        roomName: messageRoom.name,
        sender: message.sender,
        text: text,
      );
    }
    _scrollMessagesToBottom();
  }

  void _showNotification({
    required String roomName,
    required String sender,
    required String text,
  }) {
    if (Compatibility.canUseSystemNotifications) {
      NotificationService.showMessage(
        roomName: roomName,
        sender: sender,
        text: text,
      );
      return;
    }
    _showInAppNotification(roomName: roomName, sender: sender, text: text);
  }

  void _showInAppNotification({
    required String roomName,
    required String sender,
    required String text,
  }) {
    final id = _nextInAppNotificationId++;
    final expiredIds = <int>[];
    setState(() {
      _inAppNotifications.add(
        _InAppNotification(
          id: id,
          roomName: roomName,
          sender: sender,
          text: text,
        ),
      );
      final overflow = (_inAppNotifications.length - 3).clamp(0, 99);
      if (overflow > 0) {
        expiredIds.addAll(
          _inAppNotifications
              .take(overflow)
              .map((notification) => notification.id),
        );
        _inAppNotifications.removeRange(0, overflow);
      }
    });
    for (final expiredId in expiredIds) {
      _inAppNotificationTimers.remove(expiredId)?.cancel();
    }
    unawaited(NativeWindow.setNotificationTopMost(true));
    _inAppNotificationTimers[id] = Timer(const Duration(seconds: 5), () {
      if (!mounted) {
        return;
      }
      setState(() {
        _inAppNotifications.removeWhere(
          (notification) => notification.id == id,
        );
      });
      _inAppNotificationTimers.remove(id);
      if (_inAppNotifications.isEmpty) {
        unawaited(NativeWindow.setNotificationTopMost(false));
      }
    });
  }

  void _scrollMessagesToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_messagesScrollController.hasClients) {
        return;
      }
      _messagesScrollController.animateTo(
        _messagesScrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scan() {
    setState(() => _scanning = true);
    _network.startDiscovery();
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _scanning = false);
      }
    });
  }

  Future<void> _createRoom() async {
    final name = _roomController.text.trim();
    if (name.isEmpty) return;
    try {
      final room = await _network.hostRoom(name: name, relay: _relayEnabled);
      setState(() {
        _activeRoom = room;
        _savedJoinedRooms[room.id] = room;
        _roomPrefs[room.id] = (_roomPrefs[room.id] ?? const _RoomPrefs())
            .copyWith(hidden: false);
        _error = null;
      });
      await _saveSavedRooms();
      await _saveRoomPrefs();
      _appendMessage(
        ChatMessage(
          sender: '系统',
          text: '聊天室已创建，你是房主。',
          system: true,
          roomId: room.id,
        ),
      );
    } catch (e) {
      setState(() => _error = '创建失败：$e');
    }
  }

  Future<void> _join(DiscoveredRoom room) async {
    try {
      await _network.joinRoom(
        room,
        displayName: _nameController.text.trim(),
        relay: _relayEnabled,
      );
      setState(() {
        _activeRoom = room;
        _savedJoinedRooms[room.id] = room;
        _roomPrefs[room.id] = (_roomPrefs[room.id] ?? const _RoomPrefs())
            .copyWith(hidden: false);
        _error = null;
      });
      unawaited(_saveSavedRooms());
      unawaited(_saveRoomPrefs());
      _appendMessage(
        ChatMessage(
          sender: '系统',
          text: '已连接到 ${room.name}。',
          system: true,
          roomId: room.id,
        ),
      );
    } catch (e) {
      setState(() => _error = '连接失败：$e');
    }
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _activeRoom == null) return;
    final roomId = _activeRoom!.id;
    _messageController.clear();
    await _network.send(text, sender: _nameController.text.trim());
    await Future<void>.delayed(Duration.zero);
    await _saveMessagesForRoom(roomId);
  }

  void _insertMessageNewline() {
    final selection = _messageController.selection;
    final text = _messageController.text;
    final start = selection.start < 0 ? text.length : selection.start;
    final end = selection.end < 0 ? text.length : selection.end;
    final nextText = text.replaceRange(start, end, '\n');
    _messageController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: start + 1),
    );
  }

  void _showOobeDialog() {
    final oobeNameController = TextEditingController(
      text: _nameController.text,
    );
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('欢迎使用 Fast Chat'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('先设置一个昵称，之后会自动保存。'),
            const SizedBox(height: 14),
            TextField(
              controller: oobeNameController,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: '你的昵称',
                prefixIcon: Icon(Icons.person_outline),
              ),
              onSubmitted: (_) {
                unawaited(
                  _finishOobe(oobeNameController, Navigator.of(context)),
                );
              },
            ),
            const SizedBox(height: 12),
            const _OobeTipRow(icon: Icons.radar, text: '左侧点击扫描局域网，找到别人创建的房间。'),
            const SizedBox(height: 8),
            const _OobeTipRow(
              icon: Icons.add_circle_outline,
              text: '左侧可以创建多个房间，创建后会自动广播。',
            ),
            const SizedBox(height: 8),
            const _OobeTipRow(
              icon: Icons.send_rounded,
              text: '消息框 Enter 发送，Shift+Enter 换行；消息可框选复制。',
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () {
              unawaited(_finishOobe(oobeNameController, Navigator.of(context)));
            },
            child: const Text('开始使用'),
          ),
        ],
      ),
    ).whenComplete(oobeNameController.dispose);
  }

  Future<void> _sendFile() async {
    if (_activeRoom == null) {
      return;
    }
    final roomId = _activeRoom!.id;
    final result = await FilePicker.pickFiles();
    final file = result?.files.single;
    if (file == null) {
      return;
    }
    final bytes = await file.readAsBytes();
    await _network.sendFile(
      sender: _nameController.text.trim(),
      fileName: file.name,
      fileSize: bytes.length,
      base64Data: base64Encode(bytes),
    );
    await Future<void>.delayed(Duration.zero);
    await _saveMessagesForRoom(roomId);
  }

  Future<void> _leave() async {
    final room = _activeRoom;
    await _network.leaveRoom();
    setState(() {
      _activeRoom = null;
    });
    _appendMessage(
      ChatMessage(
        sender: '系统',
        text: '已离开聊天室。',
        system: true,
        roomId: room?.id,
      ),
    );
  }

  Future<void> _openRoom(DiscoveredRoom room) async {
    try {
      if (_network.roomId == room.id ||
          _hostedRooms.any((r) => r.id == room.id) ||
          _joinedRooms.any((r) => r.id == room.id)) {
        await _network.activateRoom(room.id);
      } else {
        await _network.joinRoom(
          room,
          displayName: _nameController.text.trim(),
          relay: room.relay,
        );
      }
      setState(() {
        _activeRoom = room;
        _error = null;
      });
      _appendMessage(
        ChatMessage(
          sender: '系统',
          text: '已切换到 ${room.name}。',
          system: true,
          roomId: room.id,
        ),
      );
    } catch (e) {
      setState(() {
        _activeRoom = room;
        _error = '连接失败：$e';
      });
    }
  }

  Future<void> _closeHostedRoom(DiscoveredRoom room) async {
    await _network.closeRoom(room.id);
    if (_activeRoom?.id == room.id) {
      setState(() => _activeRoom = null);
    }
    _appendMessage(
      ChatMessage(
        sender: '系统',
        text: '已关闭房间 ${room.name}。',
        system: true,
        roomId: room.id,
      ),
    );
  }

  Future<void> _closeJoinedRoom(DiscoveredRoom room) async {
    await _network.closeRoom(room.id);
    if (_activeRoom?.id == room.id) {
      setState(() => _activeRoom = null);
    }
    _appendMessage(
      ChatMessage(
        sender: '系统',
        text: '已离开房间 ${room.name}。',
        system: true,
        roomId: room.id,
      ),
    );
  }

  Future<void> _deleteRoom(DiscoveredRoom room) async {
    await _network.closeRoom(room.id);
    setState(() {
      _savedJoinedRooms.remove(room.id);
      _roomPrefs[room.id] = (_roomPrefs[room.id] ?? const _RoomPrefs())
          .copyWith(hidden: true, pinned: false, muted: false);
      _messagesByRoom.remove(room.id);
      if (_activeRoom?.id == room.id) {
        _activeRoom = null;
      }
    });
    unawaited(_saveSavedRooms());
    unawaited(_saveRoomPrefs());
    unawaited(_removeMessagesForRoom(room.id));
  }

  Future<void> _handleRoomAction(
    DiscoveredRoom room,
    _RoomAction action,
  ) async {
    final prefs = _roomPrefs[room.id] ?? const _RoomPrefs();
    if (action == _RoomAction.pin) {
      setState(() {
        _roomPrefs[room.id] = prefs.copyWith(pinned: !prefs.pinned);
      });
      unawaited(_saveRoomPrefs());
    } else if (action == _RoomAction.mute) {
      setState(() {
        _roomPrefs[room.id] = prefs.copyWith(muted: !prefs.muted);
      });
      unawaited(_saveRoomPrefs());
    } else if (action == _RoomAction.delete) {
      await _deleteRoom(room);
    }
  }

  Future<void> _showRoomContextMenu(
    DiscoveredRoom room,
    Offset position,
  ) async {
    final prefs = _roomPrefs[room.id] ?? const _RoomPrefs();
    final action = await showMenu<_RoomAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: _RoomAction.pin,
          child: Row(
            children: [
              Icon(prefs.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              const SizedBox(width: 10),
              Text(prefs.pinned ? '取消置顶' : '置顶'),
            ],
          ),
        ),
        PopupMenuItem(
          value: _RoomAction.mute,
          child: Row(
            children: [
              Icon(
                prefs.muted
                    ? Icons.notifications_active_outlined
                    : Icons.notifications_off_outlined,
              ),
              const SizedBox(width: 10),
              Text(prefs.muted ? '取消免打扰' : '免打扰'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _RoomAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.red),
              SizedBox(width: 10),
              Text('删除聊天室', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );
    if (action != null) {
      await _handleRoomAction(room, action);
    }
  }

  void _showCreateDialog() {
    _roomController.clear();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('创建聊天室'),
        content: TextField(
          controller: _roomController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '聊天室名称',
            hintText: '例如：产品讨论组',
          ),
          onSubmitted: (_) {
            Navigator.pop(context);
            _createRoom();
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.pop(context);
              _createRoom();
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }

  void _showSettingsDialog() {
    final settingsNameController = TextEditingController(
      text: _nameController.text,
    );
    var muted = _globalMuted;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: settingsNameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '用户名',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: muted,
                onChanged: (value) {
                  setDialogState(() => muted = value);
                },
                title: const Text('全局免打扰'),
                subtitle: const Text('开启后不再弹出任何新消息通知'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final prefs = await SharedPreferences.getInstance();
                final name = settingsNameController.text.trim();
                if (name.isNotEmpty) {
                  _nameController.text = name;
                  await prefs.setString(_prefDisplayName, name);
                }
                await prefs.setBool(_prefGlobalMuted, muted);
                if (!mounted) {
                  return;
                }
                setState(() => _globalMuted = muted);
                if (navigator.mounted) {
                  navigator.pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    ).whenComplete(settingsNameController.dispose);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final compact = constraints.maxWidth < 800;
                final compactRoomHeight = (constraints.maxHeight * 0.36).clamp(
                  220.0,
                  320.0,
                );
                return Column(
                  children: [
                    _buildHeader(compact: compact),
                    Expanded(
                      child: compact
                          ? Column(
                              children: [
                                SizedBox(
                                  height: compactRoomHeight,
                                  child: _buildRoomPanel(compact: compact),
                                ),
                                Expanded(child: _buildChatPanel()),
                              ],
                            )
                          : Row(
                              children: [
                                SizedBox(
                                  width: 330,
                                  child: _buildRoomPanel(compact: compact),
                                ),
                                Expanded(child: _buildChatPanel()),
                              ],
                            ),
                    ),
                  ],
                );
              },
            ),
            _buildInAppNotificationHost(),
          ],
        ),
      ),
    );
  }

  Widget _buildInAppNotificationHost() {
    final notifications = _inAppNotifications
        .map(
          (notification) => TweenAnimationBuilder<double>(
            key: ValueKey(notification.id),
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            builder: (context, value, child) {
              return Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, (1 - value) * -10),
                  child: child,
                ),
              );
            },
            child: _inAppNotificationCard(notification),
          ),
        )
        .toList();
    return Positioned(
      top: 88,
      right: 18,
      child: IgnorePointer(
        ignoring: _inAppNotifications.isEmpty,
        child: SizedBox(
          width: 320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: notifications,
          ),
        ),
      ),
    );
  }

  Widget _inAppNotificationCard(_InAppNotification notification) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        elevation: 8,
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xffd7e4df)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.notifications_active_outlined,
                color: Color(0xff176b5b),
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${notification.sender} · ${notification.roomName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notification.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭通知',
                visualDensity: VisualDensity.compact,
                onPressed: () => _dismissInAppNotification(notification.id),
                icon: const Icon(Icons.close, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _dismissInAppNotification(int id) {
    _inAppNotificationTimers.remove(id)?.cancel();
    setState(() {
      _inAppNotifications.removeWhere((notification) => notification.id == id);
    });
    if (_inAppNotifications.isEmpty) {
      unawaited(NativeWindow.setNotificationTopMost(false));
    }
  }

  Widget _buildHeader({required bool compact}) => Container(
    height: 72,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    decoration: const BoxDecoration(
      color: Colors.white,
      border: Border(bottom: BorderSide(color: Color(0xffdfe7e4))),
    ),
    child: Row(
      children: [
        const Icon(Icons.forum_rounded, color: Color(0xff176b5b), size: 28),
        const SizedBox(width: 12),
        const Expanded(
          child: Text(
            'Fast Chat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
        ),
        IconButton(
          tooltip: '设置',
          onPressed: _showSettingsDialog,
          icon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _nameController,
            builder: (context, value, _) {
              final name = value.text.trim();
              return CircleAvatar(
                radius: 16,
                backgroundColor: const Color(0xffcce7df),
                foregroundColor: const Color(0xff176b5b),
                child: Text(
                  name.isEmpty ? '?' : name.characters.first,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              );
            },
          ),
        ),
      ],
    ),
  );

  Widget _buildRoomPanel({required bool compact}) => Container(
    color: const Color(0xffedf3f1),
    padding: const EdgeInsets.fromLTRB(18, 20, 18, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '局域网房间',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            if (_scanning)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            IconButton(
              tooltip: '扫描局域网',
              onPressed: _scan,
              icon: const Icon(Icons.radar),
            ),
            IconButton(
              tooltip: '创建房间',
              onPressed: _showCreateDialog,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_hostedRooms.length} 个我创建 · ${_visibleSavedJoinedRooms.length} 个已加入 · ${_visibleDiscoveredRooms.length} 个可加入',
          style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.red, fontSize: 12),
            ),
          ),
        const SizedBox(height: 14),
        Expanded(
          child:
              _hostedRooms.isEmpty &&
                  _visibleSavedJoinedRooms.isEmpty &&
                  _visibleDiscoveredRooms.isEmpty
              ? const Center(
                  child: Text(
                    '暂未发现房间\n点击左侧创建一个',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black45, height: 1.6),
                  ),
                )
              : ListView(
                  children: [
                    if (_hostedRooms.isNotEmpty)
                      _roomSection(
                        title: '我创建的房间',
                        rooms: _orderedRooms(_hostedRooms),
                        tileBuilder: (room) => _roomTile(
                          room,
                          onTap: () => _openRoom(room),
                          onSecondaryTapDown: (details) => _showRoomContextMenu(
                            room,
                            details.globalPosition,
                          ),
                          trailing: IconButton(
                            tooltip: '关闭房间',
                            onPressed: () => _closeHostedRoom(room),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ),
                      ),
                    if (_visibleSavedJoinedRooms.isNotEmpty)
                      _roomSection(
                        title: '我加入的房间',
                        rooms: _orderedRooms(_visibleSavedJoinedRooms),
                        tileBuilder: (room) => _roomTile(
                          room,
                          onTap: () => _openRoom(room),
                          onSecondaryTapDown: (details) => _showRoomContextMenu(
                            room,
                            details.globalPosition,
                          ),
                          trailing: IconButton(
                            tooltip: '离开房间',
                            onPressed: () => _closeJoinedRoom(room),
                            icon: const Icon(Icons.logout, size: 18),
                          ),
                        ),
                      ),
                    if (_visibleDiscoveredRooms.isNotEmpty)
                      _roomSection(
                        title: '局域网发现',
                        rooms: _orderedRooms(_visibleDiscoveredRooms),
                        tileBuilder: (room) => _roomTile(
                          room,
                          onTap: () => _join(room),
                          onSecondaryTapDown: (details) => _showRoomContextMenu(
                            room,
                            details.globalPosition,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
        Material(
          color: Colors.transparent,
          child: SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _relayEnabled,
            onChanged: (v) => setState(() => _relayEnabled = v),
            title: const Text('允许作为中继', style: TextStyle(fontSize: 13)),
            subtitle: const Text('帮助转发同房间消息', style: TextStyle(fontSize: 11)),
          ),
        ),
      ],
    ),
  );

  Widget _roomSection({
    required String title,
    required List<DiscoveredRoom> rooms,
    required Widget Function(DiscoveredRoom room) tileBuilder,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          ...rooms.map(
            (room) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: tileBuilder(room),
            ),
          ),
        ],
      ),
    );
  }

  Widget _roomTile(
    DiscoveredRoom room, {
    required VoidCallback onTap,
    GestureTapDownCallback? onSecondaryTapDown,
    Widget? trailing,
  }) {
    final selected = _activeRoom?.id == room.id;
    final prefs = _roomPrefs[room.id] ?? const _RoomPrefs();
    return InkWell(
      onTap: onTap,
      onSecondaryTapDown: onSecondaryTapDown,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: selected ? const Color(0xffd7ebe5) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? const Color(0xff75b7a5) : const Color(0xffe1e9e6),
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: const Color(0xffcce7df),
              foregroundColor: const Color(0xff176b5b),
              child: Text(room.name.characters.first),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '${room.host} · ${room.peers} 人${room.relay ? ' · 中继' : ''}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            if (prefs.pinned)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(Icons.push_pin, size: 15, color: Color(0xff176b5b)),
              ),
            if (prefs.muted)
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Icon(
                  Icons.notifications_off_outlined,
                  size: 15,
                  color: Colors.black45,
                ),
              ),
            trailing ??
                const Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: Colors.black38,
                ),
          ],
        ),
      ),
    );
  }

  Widget _buildChatPanel() {
    final visibleMessages = _messagesForRoom(_activeRoom?.id ?? _lobbyRoomId);
    return Column(
      children: [
        Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 24),
          decoration: const BoxDecoration(
            color: Colors.white,
            border: Border(bottom: BorderSide(color: Color(0xffdfe7e4))),
          ),
          child: Row(
            children: [
              Icon(
                _activeRoom == null
                    ? Icons.chat_bubble_outline
                    : Icons.lock_outline,
                color: const Color(0xff176b5b),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _activeRoom?.name ?? '选择一个聊天室',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    _activeRoom == null
                        ? '消息仅在局域网内传输'
                        : '${_activeRoom!.peers} 位成员在线',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                ],
              ),
              const Spacer(),
              if (_activeRoom != null)
                IconButton(
                  tooltip: '离开房间',
                  onPressed: _leave,
                  icon: const Icon(Icons.logout, size: 20),
                ),
            ],
          ),
        ),
        Expanded(
          child: visibleMessages.isEmpty
              ? const SizedBox()
              : ListView.builder(
                  controller: _messagesScrollController,
                  padding: const EdgeInsets.all(24),
                  itemCount: visibleMessages.length,
                  itemBuilder: (_, i) => _messageBubble(visibleMessages[i]),
                ),
        ),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          reverseDuration: const Duration(milliseconds: 180),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            return SizeTransition(
              sizeFactor: animation,
              alignment: const AlignmentDirectional(-1, 1),
              child: FadeTransition(opacity: animation, child: child),
            );
          },
          child: _transfers.isEmpty
              ? const SizedBox(key: ValueKey('transfer-empty'))
              : _buildTransferPanel(),
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
          color: Colors.white,
          child: Shortcuts(
            shortcuts: {
              const SingleActivator(LogicalKeyboardKey.enter):
                  const SendMessageIntent(),
              const SingleActivator(LogicalKeyboardKey.enter, shift: true):
                  const InsertNewlineIntent(),
              const SingleActivator(LogicalKeyboardKey.numpadEnter):
                  const SendMessageIntent(),
              const SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                shift: true,
              ): const InsertNewlineIntent(),
            },
            child: Actions(
              actions: {
                SendMessageIntent: CallbackAction<SendMessageIntent>(
                  onInvoke: (_) {
                    if (_activeRoom != null) {
                      _send();
                    }
                    return null;
                  },
                ),
                InsertNewlineIntent: CallbackAction<InsertNewlineIntent>(
                  onInvoke: (_) {
                    if (_activeRoom != null) {
                      _insertMessageNewline();
                    }
                    return null;
                  },
                ),
              },
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      enabled: _activeRoom != null,
                      controller: _messageController,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: _activeRoom == null
                            ? '加入房间后开始聊天'
                            : '输入消息，Enter 发送，Shift+Enter 换行',
                        filled: true,
                        fillColor: const Color(0xfff0f4f3),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 15,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton(
                    tooltip: '发送文件',
                    onPressed: _activeRoom == null ? null : _sendFile,
                    icon: const Icon(Icons.attach_file),
                  ),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: _activeRoom == null ? null : _send,
                    icon: const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTransferPanel() {
    final active = _transfers.values.toList()
      ..sort((a, b) => a.done == b.done ? 0 : (a.done ? 1 : -1));
    return Container(
      key: const ValueKey('transfer-panel'),
      color: const Color(0xffeef4f1),
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 10),
      child: Column(
        children: active.map((status) {
          final progress = status.progress.clamp(0.0, 1.0);
          final label = status.incoming ? '接收' : '发送';
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                Icon(
                  status.incoming
                      ? Icons.file_download_outlined
                      : Icons.file_upload_outlined,
                  size: 18,
                  color: const Color(0xff176b5b),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$label ${status.fileName}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: status.done ? 1 : progress,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  status.done
                      ? '完成'
                      : '${(progress * 100).toStringAsFixed(0)}%',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _messageBubble(ChatMessage message) {
    if (message.system) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: Center(
          child: Text(
            message.text,
            style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
          ),
        ),
      );
    }
    final mine = message.sender == _nameController.text.trim();
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(
          color: mine ? const Color(0xffd7ebe5) : Colors.white,
          border: Border.all(color: const Color(0xffe1e9e6)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.sender,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Color(0xff176b5b),
              ),
            ),
            const SizedBox(height: 3),
            if (message.hasFile)
              _fileTile(message)
            else
              SelectableText(message.text),
          ],
        ),
      ),
    );
  }

  Widget _fileTile(ChatMessage message) {
    final size = _formatBytes(message.fileSize ?? 0);
    return InkWell(
      onTap: () => _saveAndOpenFile(message),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        constraints: const BoxConstraints(minWidth: 220),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: const Color(0xfff0f4f3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xffdce6e2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.insert_drive_file_outlined,
              color: Color(0xff176b5b),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    message.fileName ?? '文件',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    Compatibility.canOpenSavedFiles
                        ? '点击保存并打开 · $size'
                        : '点击保存 · $size',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveAndOpenFile(ChatMessage message) async {
    final fileName = message.fileName;
    final fileData = message.fileData;
    if (fileName == null || fileData == null) {
      return;
    }
    try {
      final baseDir =
          await getDownloadsDirectory() ??
          await getApplicationDocumentsDirectory();
      final receivedDir = Directory(
        '${baseDir.path}${Platform.pathSeparator}FastChat',
      );
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      final file = File(
        '${receivedDir.path}${Platform.pathSeparator}$fileName',
      );
      await file.writeAsBytes(base64Decode(fileData));
      if (Compatibility.canOpenSavedFiles) {
        try {
          await OpenFile.open(file.path);
        } catch (_) {}
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '保存文件失败：$e');
      }
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

class _OobeTipRow extends StatelessWidget {
  const _OobeTipRow({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: const Color(0xff176b5b)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 12, color: Colors.black54),
          ),
        ),
      ],
    );
  }
}
