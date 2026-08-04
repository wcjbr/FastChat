import 'dart:async';
import 'package:flutter/material.dart';
import 'network/network_service.dart';

void main() => runApp(const FastChatApp());

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
  final List<ChatMessage> _messages = [
    ChatMessage(sender: '系统', text: '欢迎使用 Fast Chat，正在扫描局域网聊天室。', system: true),
  ];
  StreamSubscription? _roomsSub;
  StreamSubscription? _messagesSub;
  List<DiscoveredRoom> _rooms = [];
  DiscoveredRoom? _activeRoom;
  bool _relayEnabled = true;
  bool _scanning = true;
  String? _error;
  Timer? _scanTimer;

  @override
  void initState() {
    super.initState();
    _roomsSub = _network.rooms.listen((rooms) {
      if (mounted) setState(() => _rooms = rooms);
    });
    _messagesSub = _network.messages.listen((message) {
      if (mounted) setState(() => _messages.add(message));
    });
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
    _messagesSub?.cancel();
    _scanTimer?.cancel();
    _network.dispose();
    _messageController.dispose();
    _roomController.dispose();
    _nameController.dispose();
    super.dispose();
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
      await _network.hostRoom(name: name, relay: _relayEnabled);
      setState(() {
        _activeRoom = DiscoveredRoom(
          id: _network.roomId,
          name: name,
          host: '本机',
          address: '127.0.0.1',
          port: _network.port,
          peers: 1,
          relay: _relayEnabled,
        );
        _error = null;
        _messages.add(
          ChatMessage(sender: '系统', text: '聊天室已创建，你是房主。', system: true),
        );
      });
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
        _messages.add(
          ChatMessage(sender: '系统', text: '已连接到 ${room.name}。', system: true),
        );
      });
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

  Future<void> _leave() async {
    await _network.leaveRoom();
    setState(() {
      _activeRoom = null;
      _messages.add(ChatMessage(sender: '系统', text: '已离开聊天室。', system: true));
    });
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
          '${_rooms.length} 个房间可加入',
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
                    final selected = _activeRoom?.id == room.id;
                    return InkWell(
                      onTap: () => _join(room),
                      borderRadius: BorderRadius.circular(8),
                      child: Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: selected
                              ? const Color(0xffd7ebe5)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: selected
                                ? const Color(0xff75b7a5)
                                : const Color(0xffe1e9e6),
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
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${room.host} · ${room.peers} 人${room.relay ? ' · 中继' : ''}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Icon(
                              Icons.chevron_right,
                              size: 18,
                              color: Colors.black38,
                            ),
                          ],
                        ),
                      ),
                    );
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
                padding: const EdgeInsets.all(24),
                itemCount: _messages.length,
                itemBuilder: (_, i) => _messageBubble(_messages[i]),
              ),
      ),
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
            Text(message.text),
          ],
        ),
      ),
    );
  }
}
