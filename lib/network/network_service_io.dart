import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'network_service_stub.dart';

class ChatNetworkService {
  static const _discoveryPort = 45454;
  final _roomController = StreamController<List<DiscoveredRoom>>.broadcast();
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _found = <String, DiscoveredRoom>{};
  final _seenMessages = <String>{};
  final _clients = <WebSocket>[];
  RawDatagramSocket? _udp;
  StreamSubscription<RawSocketEvent>? _udpSubscription;
  HttpServer? _server;
  WebSocket? _socket;
  Timer? _announceTimer;
  String _roomId = '';
  String _roomName = '';
  String _displayName = '访客';
  bool _hosting = false;
  bool _relay = true;
  bool _relayNode = false;

  Stream<List<DiscoveredRoom>> get rooms => _roomController.stream;
  Stream<ChatMessage> get messages => _messageController.stream;
  String get roomId => _roomId;
  int get port => _server?.port ?? 0;

  Future<void> startDiscovery() async {
    _udp ??= await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    _udp!.broadcastEnabled = true;
    _udpSubscription ??= _udp!.listen((event) {
      if (event != RawSocketEvent.read) return;
      final packet = _udp!.receive();
      if (packet == null) return;
      try {
        final json =
            jsonDecode(utf8.decode(packet.data)) as Map<String, dynamic>;
        if (json['type'] != 'fast-chat-room' || json['id'] == _roomId) return;
        final room = DiscoveredRoom(
          id: json['id'],
          name: json['name'],
          host: json['host'],
          address: packet.address.address,
          port: json['wsPort'] ?? json['port'],
          peers: json['peers'] ?? 1,
          relay: json['relay'] ?? true,
        );
        _found[room.id] = room;
        _roomController.add(_found.values.toList());
      } catch (_) {}
    });
  }

  Future<void> hostRoom({required String name, required bool relay}) async {
    await startDiscovery();
    await leaveRoom();
    _roomId =
        '${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}';
    _roomName = name;
    _hosting = true;
    _relayNode = false;
    _relay = relay;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    _server!.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = HttpStatus.badRequest;
        await request.response.close();
        return;
      }
      final webSocket = await WebSocketTransformer.upgrade(request);
      _attachSocket(webSocket);
    });
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _announce(),
    );
    _announce();
  }

  void _attachSocket(WebSocket client) {
    _clients.add(client);
    client.listen(
      (data) => _handleData(client, data.toString()),
      onDone: () => _clients.remove(client),
      onError: (_) => _clients.remove(client),
    );
  }

  void _handleData(WebSocket source, String data) {
    for (final line in data.split('\n')) {
      if (line.trim().isEmpty) continue;
      try {
        final packet = jsonDecode(line) as Map<String, dynamic>;
        final id = packet['id']?.toString();
        if (id == null || _seenMessages.contains(id)) {
          continue;
        }
        _seenMessages.add(id);
        if (packet['type'] == 'message') {
          final message = ChatMessage(
            sender: packet['sender'] ?? '访客',
            text: packet['text'] ?? '',
          );
          _messageController.add(message);
          if (_relay) {
            final encoded = '${jsonEncode(packet)}\n';
            for (final client in List<WebSocket>.from(_clients)) {
              if (client != source) {
                client.add(encoded);
              }
            }
            if (source != _socket) {
              _socket?.add(encoded);
            }
          }
        }
      } catch (_) {}
    }
  }

  Future<void> joinRoom(
    DiscoveredRoom room, {
    required String displayName,
    required bool relay,
  }) async {
    await startDiscovery();
    await leaveRoom();
    _displayName = displayName.isEmpty ? '访客' : displayName;
    _relay = relay;
    _socket = await WebSocket.connect('ws://${room.address}:${room.port}');
    _socket!.listen(
      (data) => _handleData(_socket!, data.toString()),
      onDone: () => _socket = null,
      onError: (_) => _socket = null,
    );
    if (_relay) {
      _hosting = true;
      _relayNode = true;
      _roomId = room.id;
      _roomName = room.name;
      _server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server!.listen((request) async {
        if (!WebSocketTransformer.isUpgradeRequest(request)) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
          return;
        }
        final webSocket = await WebSocketTransformer.upgrade(request);
        _attachSocket(webSocket);
      });
      _announceTimer?.cancel();
      _announceTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _announce(),
      );
      _announce();
    }
  }

  Future<void> send(String text, {required String sender}) async {
    final packet = {
      'type': 'message',
      'id':
          '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(999999)}',
      'sender': sender.isEmpty ? _displayName : sender,
      'text': text,
      'time': DateTime.now().toIso8601String(),
    };
    final encoded = '${jsonEncode(packet)}\n';
    _seenMessages.add(packet['id'] as String);
    if (_hosting) {
      _messageController.add(
        ChatMessage(sender: packet['sender'] as String, text: text),
      );
      for (final client in List<WebSocket>.from(_clients)) {
        client.add(encoded);
      }
      _socket?.add(encoded);
    } else {
      _socket?.add(encoded);
    }
  }

  void _announce() {
    if (!_hosting || _udp == null || _server == null) return;
    final packet = utf8.encode(
      jsonEncode({
        'type': 'fast-chat-room',
        'id': _roomId,
        'name': _roomName,
        'host': _relayNode ? '中继节点' : '本机房主',
        'wsPort': _server!.port,
        'port': _server!.port,
        'peers': _clients.length + 1,
        'relay': _relay,
      }),
    );
    _udp!.send(packet, InternetAddress('255.255.255.255'), _discoveryPort);
  }

  Future<void> leaveRoom() async {
    _announceTimer?.cancel();
    await _socket?.close();
    _socket = null;
    for (final client in List<WebSocket>.from(_clients)) {
      await client.close();
    }
    _clients.clear();
    await _server?.close();
    _server = null;
    _hosting = false;
    _relayNode = false;
    _seenMessages.clear();
    _roomId = '';
    _roomName = '';
  }

  Future<void> dispose() async {
    await leaveRoom();
    await _udpSubscription?.cancel();
    _udp?.close();
    await _roomController.close();
    await _messageController.close();
  }
}
