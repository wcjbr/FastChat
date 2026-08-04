import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'network_service_stub.dart';

class ChatNetworkService {
  static const _discoveryPort = 45454;
  static const int _fileChunkSize = 48 * 1024;
  final _roomController = StreamController<List<DiscoveredRoom>>.broadcast();
  final _messageController = StreamController<ChatMessage>.broadcast();
  final _transferController = StreamController<FileTransferStatus>.broadcast();
  final _found = <String, DiscoveredRoom>{};
  final _seenMessages = <String>{};
  final _incomingFiles = <String, _IncomingFileTransfer>{};
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
  Stream<FileTransferStatus> get transfers => _transferController.stream;
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
        final type = packet['type'];
        if (type == 'message') {
          _messageController.add(
            ChatMessage(
              sender: packet['sender'] ?? '访客',
              text: packet['text'] ?? '',
            ),
          );
        } else if (type == 'file-start') {
          final transferId = packet['transferId']?.toString();
          if (transferId == null) continue;
          _incomingFiles[transferId] = _IncomingFileTransfer(
            sender: packet['sender'] ?? '访客',
            fileName: packet['fileName'] ?? '文件',
            fileSize: packet['fileSize'] ?? 0,
            totalChunks: packet['totalChunks'] ?? 0,
          );
          _transferController.add(
            FileTransferStatus(
              transferId: transferId,
              fileName: packet['fileName'] ?? '文件',
              sender: packet['sender'] ?? '访客',
              totalBytes: packet['fileSize'] ?? 0,
              transferredBytes: 0,
              incoming: true,
              phase: 'receiving',
            ),
          );
        } else if (type == 'file-chunk') {
          final transferId = packet['transferId']?.toString();
          final chunkData = packet['data']?.toString();
          if (transferId == null || chunkData == null) continue;
          final transfer = _incomingFiles.putIfAbsent(
            transferId,
            () => _IncomingFileTransfer(
              sender: packet['sender'] ?? '访客',
              fileName: packet['fileName'] ?? '文件',
              fileSize: packet['fileSize'] ?? 0,
              totalChunks: packet['totalChunks'] ?? 0,
            ),
          );
          final chunkBytes = base64Decode(chunkData);
          transfer.addChunk(chunkBytes);
          _transferController.add(
            FileTransferStatus(
              transferId: transferId,
              fileName: transfer.fileName,
              sender: transfer.sender,
              totalBytes: transfer.fileSize,
              transferredBytes: transfer.receivedBytes,
              incoming: true,
              phase: 'receiving',
            ),
          );
        } else if (type == 'file-end') {
          final transferId = packet['transferId']?.toString();
          if (transferId == null) continue;
          final transfer = _incomingFiles.remove(transferId);
          if (transfer == null) continue;
          final bytes = transfer.bytes.toBytes();
          _messageController.add(
            ChatMessage(
              sender: transfer.sender,
              text: '发送了文件：${transfer.fileName}',
              fileName: transfer.fileName,
              fileSize: transfer.fileSize,
              fileData: base64Encode(bytes),
            ),
          );
          _transferController.add(
            FileTransferStatus(
              transferId: transferId,
              fileName: transfer.fileName,
              sender: transfer.sender,
              totalBytes: transfer.fileSize,
              transferredBytes: transfer.fileSize,
              incoming: true,
              phase: 'done',
            ),
          );
        }
        if (type == 'message' ||
            type == 'file-start' ||
            type == 'file-chunk' ||
            type == 'file-end') {
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

  Future<void> sendFile({
    required String sender,
    required String fileName,
    required int fileSize,
    required String base64Data,
  }) async {
    final bytes = base64Decode(base64Data);
    final transferId =
        '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(999999)}';
    final totalChunks = (bytes.length / _fileChunkSize).ceil();
    final displayName = sender.isEmpty ? _displayName : sender;
    _transferController.add(
      FileTransferStatus(
        transferId: transferId,
        fileName: fileName,
        sender: displayName,
        totalBytes: fileSize,
        transferredBytes: 0,
        incoming: false,
        phase: 'sending',
      ),
    );
    _messageController.add(
      ChatMessage(
        sender: displayName,
        text: '发送了文件：$fileName',
        fileName: fileName,
        fileSize: fileSize,
        fileData: base64Data,
      ),
    );

    final packet = {
      'type': 'file-start',
      'id': '$transferId-start',
      'transferId': transferId,
      'sender': displayName,
      'text': '发送了文件：$fileName',
      'fileName': fileName,
      'fileSize': fileSize,
      'chunkSize': _fileChunkSize,
      'totalChunks': totalChunks,
      'time': DateTime.now().toIso8601String(),
    };
    await _sendPacket(packet);

    for (var index = 0; index < totalChunks; index++) {
      final start = index * _fileChunkSize;
      final end = min(start + _fileChunkSize, bytes.length);
      final chunk = bytes.sublist(start, end);
      await _sendPacket({
        'type': 'file-chunk',
        'id': '$transferId-chunk-$index',
        'transferId': transferId,
        'sender': displayName,
        'fileName': fileName,
        'fileSize': fileSize,
        'totalChunks': totalChunks,
        'index': index,
        'data': base64Encode(chunk),
        'time': DateTime.now().toIso8601String(),
      });
      _transferController.add(
        FileTransferStatus(
          transferId: transferId,
          fileName: fileName,
          sender: displayName,
          totalBytes: fileSize,
          transferredBytes: min(end, fileSize),
          incoming: false,
          phase: 'sending',
        ),
      );
    }

    await _sendPacket({
      'type': 'file-end',
      'id': '$transferId-end',
      'transferId': transferId,
      'sender': displayName,
      'fileName': fileName,
      'fileSize': fileSize,
      'totalChunks': totalChunks,
      'time': DateTime.now().toIso8601String(),
    });
    _transferController.add(
      FileTransferStatus(
        transferId: transferId,
        fileName: fileName,
        sender: displayName,
        totalBytes: fileSize,
        transferredBytes: fileSize,
        incoming: false,
        phase: 'done',
      ),
    );
  }

  Future<void> _sendPacket(Map<String, dynamic> packet) async {
    final encoded = '${jsonEncode(packet)}\n';
    _seenMessages.add(packet['id'] as String);
    if (_hosting) {
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
    await _transferController.close();
  }
}

class _IncomingFileTransfer {
  _IncomingFileTransfer({
    required this.sender,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
  });

  final String sender;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final BytesBuilder bytes = BytesBuilder(copy: false);
  int receivedBytes = 0;

  void addChunk(List<int> chunk) {
    bytes.add(chunk);
    receivedBytes += chunk.length;
  }
}
