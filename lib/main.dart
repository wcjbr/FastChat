import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'package:path_provider/path_provider.dart';
import 'compat/compatibility.dart';
import 'network/network_service.dart';
import 'notifications/notification_service.dart';

void main(List<String> args) {
  Compatibility.initialize(args);
  runApp(const FastChatApp());
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
  final _network = ChatNetworkService();
  final _messageController = TextEditingController();
  final _roomController = TextEditingController();
  final _nameController = TextEditingController(text: '访客');
  final _messagesScrollController = ScrollController();
  final List<ChatMessage> _messages = [
    ChatMessage(sender: '系统', text: '欢迎使用 Fast Chat，正在扫描局域网聊天室。', system: true),
  ];
  StreamSubscription? _roomsSub;
  StreamSubscription? _hostedRoomsSub;
  StreamSubscription? _messagesSub;
  StreamSubscription? _transfersSub;
  List<DiscoveredRoom> _rooms = [];
  List<DiscoveredRoom> _hostedRooms = [];
  DiscoveredRoom? _activeRoom;
  bool _relayEnabled = true;
  bool _scanning = true;
  String? _error;
  Timer? _scanTimer;
  final Map<String, FileTransferStatus> _transfers = {};

  @override
  void initState() {
    super.initState();
    _roomsSub = _network.rooms.listen((rooms) {
      if (mounted) setState(() => _rooms = rooms);
    });
    _hostedRoomsSub = _network.hostedRooms.listen((rooms) {
      if (mounted) setState(() => _hostedRooms = rooms);
    });
    _messagesSub = _network.messages.listen((message) {
      if (mounted) {
        _appendMessage(message);
      }
    });
    _transfersSub = _network.transfers.listen((status) {
      if (!mounted) return;
      setState(() {
        _transfers[status.transferId] = status;
      });
    });
    NotificationService.initialize();
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
    _messagesSub?.cancel();
    _transfersSub?.cancel();
    _scanTimer?.cancel();
    _network.dispose();
    _messageController.dispose();
    _roomController.dispose();
    _nameController.dispose();
    _messagesScrollController.dispose();
    super.dispose();
  }

  void _appendMessage(ChatMessage message) {
    setState(() => _messages.add(message));
    final currentName = _nameController.text.trim();
    if (!message.system &&
        message.sender != currentName &&
        _activeRoom != null) {
      NotificationService.showMessage(
        roomName: _activeRoom!.name,
        sender: message.sender,
        text: message.hasFile ? '发送了文件：${message.fileName}' : message.text,
      );
    }
    _scrollMessagesToBottom();
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
        _error = null;
      });
      _appendMessage(
        ChatMessage(sender: '系统', text: '聊天室已创建，你是房主。', system: true),
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
        _error = null;
      });
      _appendMessage(
        ChatMessage(sender: '系统', text: '已连接到 ${room.name}。', system: true),
      );
    } catch (e) {
      setState(() => _error = '连接失败：$e');
    }
  }

  Future<void> _send() async {
    final text = _messageController.text.trim();
    if (text.isEmpty || _activeRoom == null) return;
    _messageController.clear();
    await _network.send(text, sender: _nameController.text.trim());
  }

  Future<void> _sendFile() async {
    if (_activeRoom == null) {
      return;
    }
    final result = await FilePicker.pickFiles(withData: true);
    final file = result?.files.single;
    final bytes = file?.bytes;
    if (file == null || bytes == null) {
      return;
    }
    await _network.sendFile(
      sender: _nameController.text.trim(),
      fileName: file.name,
      fileSize: bytes.length,
      base64Data: base64Encode(bytes),
    );
  }

  Future<void> _leave() async {
    await _network.leaveRoom();
    setState(() {
      _activeRoom = null;
    });
    _appendMessage(ChatMessage(sender: '系统', text: '已离开聊天室。', system: true));
  }

  Future<void> _openHostedRoom(DiscoveredRoom room) async {
    await _network.activateRoom(room.id);
    setState(() {
      _activeRoom = room;
      _error = null;
    });
    _appendMessage(
      ChatMessage(sender: '系统', text: '已切换到 ${room.name}。', system: true),
    );
  }

  Future<void> _closeHostedRoom(DiscoveredRoom room) async {
    await _network.closeRoom(room.id);
    if (_activeRoom?.id == room.id) {
      setState(() => _activeRoom = null);
    }
    _appendMessage(
      ChatMessage(sender: '系统', text: '已关闭房间 ${room.name}。', system: true),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 800;
            final compactRoomHeight = (constraints.maxHeight * 0.36).clamp(
              220.0,
              320.0,
            );
            return Column(
              children: [
                _buildHeader(),
                Expanded(
                  child: compact
                      ? Column(
                          children: [
                            SizedBox(
                              height: compactRoomHeight,
                              child: _buildRoomPanel(),
                            ),
                            Expanded(child: _buildChatPanel()),
                          ],
                        )
                      : Row(
                          children: [
                            SizedBox(width: 330, child: _buildRoomPanel()),
                            Expanded(child: _buildChatPanel()),
                          ],
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader() => Container(
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
        const Flexible(
          child: Text(
            'Fast Chat',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
          ),
        ),
        const Spacer(),
        SizedBox(
          width: 132,
          child: TextField(
            controller: _nameController,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.person_outline, size: 19),
              hintText: '你的昵称',
              border: InputBorder.none,
            ),
          ),
        ),
        const SizedBox(width: 12),
        IconButton(
          tooltip: '扫描局域网',
          onPressed: _scan,
          icon: const Icon(Icons.radar),
        ),
      ],
    ),
  );

  Widget _buildRoomPanel() => Container(
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
              tooltip: '创建房间',
              onPressed: _showCreateDialog,
              icon: const Icon(Icons.add_circle_outline),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${_hostedRooms.length} 个我创建 · ${_rooms.length} 个可加入',
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
        if (_hostedRooms.isNotEmpty) ...[
          const Text(
            '我的房间',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: (_hostedRooms.length * 76.0).clamp(76.0, 180.0),
            child: ListView.separated(
              itemCount: _hostedRooms.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final room = _hostedRooms[index];
                return _roomTile(
                  room,
                  onTap: () => _openHostedRoom(room),
                  trailing: IconButton(
                    tooltip: '关闭房间',
                    onPressed: () => _closeHostedRoom(room),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          const Text(
            '发现的房间',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
        ],
        Expanded(
          child: _rooms.isEmpty
              ? const Center(
                  child: Text(
                    '暂未发现房间\n点击右上角创建一个',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.black45, height: 1.6),
                  ),
                )
              : ListView.separated(
                  itemCount: _rooms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final room = _rooms[index];
                    return _roomTile(room, onTap: () => _join(room));
                  },
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

  Widget _roomTile(
    DiscoveredRoom room, {
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    final selected = _activeRoom?.id == room.id;
    return InkWell(
      onTap: onTap,
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

  Widget _buildChatPanel() => Column(
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
        child: _messages.isEmpty
            ? const SizedBox()
            : ListView.builder(
                controller: _messagesScrollController,
                padding: const EdgeInsets.all(24),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _messageBubble(_messages[i]),
              ),
      ),
      if (_transfers.isNotEmpty) _buildTransferPanel(),
      Container(
        padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
        color: Colors.white,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                enabled: _activeRoom != null,
                controller: _messageController,
                minLines: 1,
                maxLines: 4,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: _activeRoom == null ? '加入房间后开始聊天' : '输入消息...',
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
    ],
  );

  Widget _buildTransferPanel() {
    final active = _transfers.values.toList()
      ..sort((a, b) => a.done == b.done ? 0 : (a.done ? 1 : -1));
    return Container(
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
            if (message.hasFile) _fileTile(message) else Text(message.text),
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
