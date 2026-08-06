import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_file/open_file.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' show RSAPublicKey;
import 'package:shared_preferences/shared_preferences.dart';
import 'acgo/acgo_binding_service.dart';
import 'acgo/acgo_e2ee.dart';
import 'acgo/acgo_private_message_service.dart';
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
    if (!Compatibility.canUseTopMostInAppNotifications) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setNotificationTopMost', enabled);
    } catch (_) {}
  }
}

enum _RoomAction { pin, mute, delete }

enum _AcgoConversationAction { pin, delete }

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

abstract class _AppStorage {
  Future<String?> getString(String key);
  Future<bool?> getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
  Future<void> remove(String key);
}

class _SharedPrefsStorage implements _AppStorage {
  _SharedPrefsStorage(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<String?> getString(String key) async => _prefs.getString(key);

  @override
  Future<bool?> getBool(String key) async => _prefs.getBool(key);

  @override
  Future<void> setString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> setBool(String key, bool value) async {
    await _prefs.setBool(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}

class _PortableFileStorage implements _AppStorage {
  _PortableFileStorage(this.rootDirectory);

  final String rootDirectory;
  Map<String, dynamic>? _cache;

  Directory get dataDirectory =>
      Directory('$rootDirectory${Platform.pathSeparator}fastchat');

  File get configFile =>
      File('${dataDirectory.path}${Platform.pathSeparator}config.json');

  @override
  Future<String?> getString(String key) async {
    final data = await _read();
    final value = data[key];
    return value is String ? value : null;
  }

  @override
  Future<bool?> getBool(String key) async {
    final data = await _read();
    final value = data[key];
    return value is bool ? value : null;
  }

  @override
  Future<void> setString(String key, String value) async {
    final data = await _read();
    data[key] = value;
    await _write(data);
  }

  @override
  Future<void> setBool(String key, bool value) async {
    final data = await _read();
    data[key] = value;
    await _write(data);
  }

  @override
  Future<void> remove(String key) async {
    final data = await _read();
    data.remove(key);
    await _write(data);
  }

  Future<Map<String, dynamic>> _read() async {
    final cached = _cache;
    if (cached != null) return cached;
    try {
      if (!await configFile.exists()) {
        _cache = <String, dynamic>{};
        return _cache!;
      }
      final decoded = jsonDecode(await configFile.readAsString());
      _cache = decoded is Map ? Map<String, dynamic>.from(decoded) : {};
      return _cache!;
    } catch (_) {
      _cache = <String, dynamic>{};
      return _cache!;
    }
  }

  Future<void> _write(Map<String, dynamic> data) async {
    if (!await dataDirectory.exists()) {
      await dataDirectory.create(recursive: true);
    }
    await configFile.writeAsString(jsonEncode(data));
  }
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
  static const _prefSignature = 'signature';
  static const _prefBirthday = 'birthday';
  static const _prefAvatarData = 'avatar_data';
  static const _prefOobeDone = 'oobe_done';
  static const _prefGlobalMuted = 'global_muted';
  static const _prefSavedRooms = 'saved_rooms';
  static const _prefRoomPrefs = 'room_prefs';
  static const _prefRoomMessages = 'room_messages';
  static const _prefAcgoProfile = 'acgo_profile';
  static const _prefAcgoAccessToken = 'acgo_access_token';
  static const _prefAcgoConversationPrefs = 'acgo_conversation_prefs';
  static const _prefDownloadDirectory = 'download_directory';
  static const _prefAcgoE2eeIdentity = 'acgo_e2ee_identity';
  static const _prefAcgoPeerKeys = 'acgo_peer_keys';
  static const _prefPortableMode = 'portable_mode';
  static const _prefPortableRootDirectory = 'portable_root_directory';
  static const _lobbyRoomId = '__lobby__';
  static const _messageWindowBatchSize = 80;

  final _acgoService = AcgoBindingService();
  final _network = ChatNetworkService();
  final _messageController = TextEditingController();
  final _roomController = TextEditingController();
  final _acgoReceiverController = TextEditingController();
  final _nameController = TextEditingController(text: '访客');
  final _signatureController = TextEditingController();
  String _birthday = '';
  String _avatarData = '';
  String _downloadDirectory = '';
  bool _portableMode = false;
  String _portableRootDirectory = '';
  _AppStorage? _storage;
  AcgoProfileSummary? _acgoProfile;
  String _acgoAccessToken = '';
  AcgoPrivateMessageService? _acgoPrivateService;
  List<AcgoPrivateConversation> _acgoConversations = [];
  final Map<String, List<ChatMessage>> _acgoMessagesByConversation = {};
  final Map<String, _RoomPrefs> _acgoConversationPrefs = {};
  final Map<String, RSAPublicKey> _acgoPeerKeys = {};
  final Set<String> _advertisedAcgoKeyConversations = {};
  AcgoE2eeIdentity? _acgoE2eeIdentity;
  AcgoPrivateConversation? _activeAcgoConversation;
  bool _loadingAcgoConversations = false;
  bool _loadingAcgoMessages = false;
  bool _sendingAcgoMessage = false;
  final _messagesScrollController = ScrollController();
  final ValueNotifier<int> _messagesVersion = ValueNotifier<int>(0);
  final Map<String, int> _messageWindowLimits = {};
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
  Timer? _messageSaveTimer;
  final Map<String, FileTransferStatus> _transfers = {};
  final Map<String, MemoryImage> _avatarImageCache = {};
  final Map<String, Uint8List> _imageBytesCache = {};
  final Map<String, Timer> _transferCleanupTimers = {};
  final List<_InAppNotification> _inAppNotifications = [];
  final Map<int, Timer> _inAppNotificationTimers = {};
  int _nextInAppNotificationId = 1;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    _messagesScrollController.addListener(_maybeLoadOlderMessages);
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
    unawaited(_startDiscoverySafely());
    _scanTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _scanning = false);
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _messagesScrollController.removeListener(_maybeLoadOlderMessages);
    _roomsSub?.cancel();
    _hostedRoomsSub?.cancel();
    _joinedRoomsSub?.cancel();
    _messagesSub?.cancel();
    _transfersSub?.cancel();
    _scanTimer?.cancel();
    _messageSaveTimer?.cancel();
    for (final timer in _transferCleanupTimers.values) {
      timer.cancel();
    }
    _transferCleanupTimers.clear();
    for (final timer in _inAppNotificationTimers.values) {
      timer.cancel();
    }
    _inAppNotificationTimers.clear();
    _acgoPrivateService?.close();
    _network.dispose();
    _messageController.dispose();
    _roomController.dispose();
    _acgoReceiverController.dispose();
    _nameController.dispose();
    _signatureController.dispose();
    _messagesScrollController.dispose();
    _messagesVersion.dispose();
    super.dispose();
  }

  Future<void> _loadPreferences() async {
    final bootstrapPrefs = await SharedPreferences.getInstance();
    final portableMode = bootstrapPrefs.getBool(_prefPortableMode) ?? false;
    final portableRoot =
        bootstrapPrefs.getString(_prefPortableRootDirectory) ?? '';
    final storage = _createStorage(
      bootstrapPrefs,
      portableMode: portableMode,
      portableRootDirectory: portableRoot,
    );
    _storage = storage;
    final savedName = (await storage.getString(_prefDisplayName))?.trim();
    final signature = await storage.getString(_prefSignature) ?? '';
    final birthday = await storage.getString(_prefBirthday) ?? '';
    final avatarData = await storage.getString(_prefAvatarData) ?? '';
    final downloadDirectory =
        await storage.getString(_prefDownloadDirectory) ?? '';
    final acgoProfile = AcgoProfileSummary.tryDecode(
      await storage.getString(_prefAcgoProfile),
    );
    final acgoAccessToken = await storage.getString(_prefAcgoAccessToken) ?? '';
    final globalMuted = await storage.getBool(_prefGlobalMuted) ?? false;
    final savedRooms = _decodeJsonList(
      await storage.getString(_prefSavedRooms),
    );
    final roomPrefs = _decodeJsonMap(await storage.getString(_prefRoomPrefs));
    final roomMessages = _decodeJsonMap(
      await storage.getString(_prefRoomMessages),
    );
    final acgoConversationPrefs = _decodeJsonMap(
      await storage.getString(_prefAcgoConversationPrefs),
    );
    var acgoE2eeIdentity = AcgoE2ee.tryDecodeIdentity(
      await storage.getString(_prefAcgoE2eeIdentity) ?? '',
    );
    if (acgoE2eeIdentity == null) {
      acgoE2eeIdentity = AcgoE2ee.generateIdentity();
      await storage.setString(
        _prefAcgoE2eeIdentity,
        AcgoE2ee.encodeIdentity(acgoE2eeIdentity),
      );
    }
    final acgoPeerKeys = _decodeAcgoPeerKeys(
      await storage.getString(_prefAcgoPeerKeys),
    );
    if (!mounted) {
      return;
    }
    setState(() {
      if (savedName != null && savedName.isNotEmpty) {
        _nameController.text = savedName;
      }
      _signatureController.text = signature;
      _birthday = birthday;
      _avatarData = avatarData;
      _downloadDirectory = downloadDirectory;
      _portableMode = portableMode;
      _portableRootDirectory = portableRoot;
      _acgoProfile = acgoProfile;
      _acgoAccessToken = acgoAccessToken;
      _acgoPrivateService = _createAcgoPrivateService(
        acgoAccessToken,
        acgoProfile,
      );
      _network.updateProfile(
        signature: signature,
        birthday: birthday,
        avatarData: avatarData,
        acgoInfo: acgoProfile?.encode() ?? '',
      );
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
      _acgoConversationPrefs
        ..clear()
        ..addEntries(
          acgoConversationPrefs.entries.map(
            (entry) => MapEntry(
              entry.key,
              _RoomPrefs.fromJson(Map<String, dynamic>.from(entry.value)),
            ),
          ),
        );
      _acgoE2eeIdentity = acgoE2eeIdentity;
      _acgoPeerKeys
        ..clear()
        ..addAll(acgoPeerKeys);
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
    if (acgoAccessToken.isNotEmpty) {
      unawaited(_loadAcgoConversations());
    }
    if (avatarData.length > 120000) {
      unawaited(_shrinkStoredAvatarData(avatarData));
    }
    if (await storage.getBool(_prefOobeDone) != true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showOobeDialog();
        }
      });
    }
  }

  _AppStorage _createStorage(
    SharedPreferences sharedPreferences, {
    required bool portableMode,
    required String portableRootDirectory,
  }) {
    if (portableMode && portableRootDirectory.trim().isNotEmpty) {
      return _PortableFileStorage(portableRootDirectory.trim());
    }
    return _SharedPrefsStorage(sharedPreferences);
  }

  Future<_AppStorage> _currentStorage() async {
    final existing = _storage;
    if (existing != null) return existing;
    final sharedPreferences = await SharedPreferences.getInstance();
    final storage = _createStorage(
      sharedPreferences,
      portableMode: sharedPreferences.getBool(_prefPortableMode) ?? false,
      portableRootDirectory:
          sharedPreferences.getString(_prefPortableRootDirectory) ?? '',
    );
    _storage = storage;
    return storage;
  }

  String _portableDataDirectoryLabel(String rootDirectory) =>
      '$rootDirectory${Platform.pathSeparator}fastchat';

  Future<void> _saveSnapshotToStorage(
    _AppStorage storage, {
    required String displayName,
    required String signature,
    required String birthday,
    required String avatarData,
    required String downloadDirectory,
    required bool globalMuted,
    required AcgoProfileSummary? acgoProfile,
    required String acgoAccessToken,
    required bool oobeDone,
  }) async {
    if (displayName.isNotEmpty) {
      await storage.setString(_prefDisplayName, displayName);
    }
    await storage.setString(_prefSignature, signature);
    await storage.setString(_prefBirthday, birthday);
    await storage.setString(_prefAvatarData, avatarData);
    await storage.setBool(_prefGlobalMuted, globalMuted);
    await storage.setBool(_prefOobeDone, oobeDone);
    if (downloadDirectory.isEmpty) {
      await storage.remove(_prefDownloadDirectory);
    } else {
      await storage.setString(_prefDownloadDirectory, downloadDirectory);
    }
    if (acgoProfile == null) {
      await storage.remove(_prefAcgoProfile);
      await storage.remove(_prefAcgoAccessToken);
    } else {
      await storage.setString(_prefAcgoProfile, acgoProfile.encode());
      if (acgoAccessToken.isNotEmpty) {
        await storage.setString(_prefAcgoAccessToken, acgoAccessToken);
      }
    }
    await storage.setString(
      _prefSavedRooms,
      jsonEncode(
        _savedJoinedRooms.values
            .where((room) => _roomPrefs[room.id]?.hidden != true)
            .map(_roomToJson)
            .toList(),
      ),
    );
    await storage.setString(
      _prefRoomPrefs,
      jsonEncode(_roomPrefs.map((key, value) => MapEntry(key, value.toJson()))),
    );
    await storage.setString(
      _prefRoomMessages,
      jsonEncode(_serializedMessages()),
    );
    await storage.setString(
      _prefAcgoConversationPrefs,
      jsonEncode(
        _acgoConversationPrefs.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      ),
    );
    final identity = _acgoE2eeIdentity;
    if (identity != null) {
      await storage.setString(
        _prefAcgoE2eeIdentity,
        AcgoE2ee.encodeIdentity(identity),
      );
    }
    await storage.setString(
      _prefAcgoPeerKeys,
      jsonEncode(
        _acgoPeerKeys.map(
          (userId, key) => MapEntry(userId, AcgoE2ee.encodePublicKey(key)),
        ),
      ),
    );
  }

  AcgoPrivateMessageService? _createAcgoPrivateService(
    String accessToken,
    AcgoProfileSummary? profile,
  ) {
    if (accessToken.isEmpty) return null;
    return AcgoPrivateMessageService(
      accessToken: accessToken,
      myUserId: profile?.userId,
    );
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

  Map<String, RSAPublicKey> _decodeAcgoPeerKeys(String? encoded) {
    final decoded = _decodeJsonMap(encoded);
    final keys = <String, RSAPublicKey>{};
    for (final entry in decoded.entries) {
      final key = AcgoE2ee.tryDecodePublicKey('${entry.value}');
      if (key != null) {
        keys[entry.key] = key;
      }
    }
    return keys;
  }

  Future<void> _saveAcgoPeerKeys() async {
    final storage = await _currentStorage();
    await storage.setString(
      _prefAcgoPeerKeys,
      jsonEncode(
        _acgoPeerKeys.map(
          (userId, key) => MapEntry(userId, AcgoE2ee.encodePublicKey(key)),
        ),
      ),
    );
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

  Future<String> _avatarDataFromBytes(List<int> bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(
        Uint8List.fromList(bytes),
        targetWidth: 128,
        targetHeight: 128,
      );
      final frame = await codec.getNextFrame();
      final byteData = await frame.image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      frame.image.dispose();
      if (byteData == null) {
        return base64Encode(bytes);
      }
      return base64Encode(byteData.buffer.asUint8List());
    } catch (_) {
      return base64Encode(bytes);
    }
  }

  Future<void> _shrinkStoredAvatarData(String avatarData) async {
    try {
      final compact = await _avatarDataFromBytes(base64Decode(avatarData));
      if (!mounted || compact.length >= avatarData.length) {
        return;
      }
      final storage = await _currentStorage();
      await storage.setString(_prefAvatarData, compact);
      if (!mounted) return;
      setState(() => _avatarData = compact);
      _network.updateProfile(
        signature: _signatureController.text.trim(),
        birthday: _birthday,
        avatarData: compact,
        acgoInfo: _acgoProfile?.encode() ?? '',
      );
    } catch (_) {}
  }

  Map<String, dynamic> _messageToJson(ChatMessage message) => {
    'sender': message.sender,
    'text': message.text,
    'system': message.system,
    'roomId': message.roomId,
    'senderSignature': message.senderSignature,
    'senderBirthday': message.senderBirthday,
    'senderAvatarData': message.senderAvatarData,
    'senderAcgoInfo': message.senderAcgoInfo,
    'fileName': message.fileName,
    'fileSize': message.fileSize,
  };

  ChatMessage _messageFromJson(Map<String, dynamic> json) => ChatMessage(
    sender: json['sender']?.toString() ?? '访客',
    text: json['text']?.toString() ?? '',
    system: json['system'] == true,
    roomId: json['roomId']?.toString(),
    senderSignature: json['senderSignature']?.toString(),
    senderBirthday: json['senderBirthday']?.toString(),
    senderAvatarData: json['senderAvatarData']?.toString(),
    senderAcgoInfo: json['senderAcgoInfo']?.toString(),
    fileName: json['fileName']?.toString(),
    fileSize: json['fileSize'] is int
        ? json['fileSize'] as int
        : int.tryParse(json['fileSize']?.toString() ?? ''),
  );

  Future<void> _saveSavedRooms() async {
    final storage = await _currentStorage();
    final visibleRooms = _savedJoinedRooms.values
        .where((room) => _roomPrefs[room.id]?.hidden != true)
        .map(_roomToJson)
        .toList();
    await storage.setString(_prefSavedRooms, jsonEncode(visibleRooms));
  }

  Future<void> _saveRoomPrefs() async {
    final storage = await _currentStorage();
    await storage.setString(
      _prefRoomPrefs,
      jsonEncode(_roomPrefs.map((key, value) => MapEntry(key, value.toJson()))),
    );
  }

  Future<void> _saveAcgoConversationPrefs() async {
    final storage = await _currentStorage();
    await storage.setString(
      _prefAcgoConversationPrefs,
      jsonEncode(
        _acgoConversationPrefs.map(
          (key, value) => MapEntry(key, value.toJson()),
        ),
      ),
    );
  }

  Future<void> _saveMessagesForRoom(String roomId) async {
    final storage = await _currentStorage();
    await storage.setString(
      _prefRoomMessages,
      jsonEncode(_serializedMessages()),
    );
  }

  void _scheduleMessagesSave(String roomId) {
    _messageSaveTimer?.cancel();
    _messageSaveTimer = Timer(const Duration(milliseconds: 120), () {
      unawaited(_saveMessagesForRoom(roomId));
    });
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
    final storage = await _currentStorage();
    final existing = _decodeJsonMap(await storage.getString(_prefRoomMessages));
    existing.remove(roomId);
    await storage.setString(_prefRoomMessages, jsonEncode(existing));
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

  String get _activeMessageListKey {
    final acgoConversation = _activeAcgoConversation;
    if (acgoConversation != null) {
      return _acgoRoomId(acgoConversation.id);
    }
    return _activeRoom?.id ?? _lobbyRoomId;
  }

  List<ChatMessage> _windowedMessages(
    String key,
    List<ChatMessage> messages,
  ) {
    final limit = (_messageWindowLimits[key] ?? _messageWindowBatchSize).clamp(
      0,
      messages.length,
    );
    if (limit >= messages.length) {
      return messages;
    }
    return messages.sublist(messages.length - limit);
  }

  void _resetMessageWindow(String key) {
    _messageWindowLimits.remove(key);
  }

  void _maybeLoadOlderMessages() {
    if (!_messagesScrollController.hasClients) {
      return;
    }
    if (_messagesScrollController.position.pixels > 160) {
      return;
    }
    final key = _activeMessageListKey;
    final messages = key.startsWith('acgo:')
        ? (_activeAcgoConversation == null
              ? const <ChatMessage>[]
              : _acgoMessagesByConversation[_activeAcgoConversation!.id] ??
                    const <ChatMessage>[])
        : _messagesForRoom(key);
    final currentLimit = _messageWindowLimits[key] ?? _messageWindowBatchSize;
    if (currentLimit >= messages.length) {
      return;
    }
    setState(() {
      _messageWindowLimits[key] =
          (currentLimit + _messageWindowBatchSize).clamp(0, messages.length);
    });
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

  List<AcgoPrivateConversation> get _visibleAcgoConversations {
    final visible = _acgoConversations
        .where(
          (conversation) =>
              _acgoConversationPrefs[conversation.id]?.hidden != true,
        )
        .toList();
    return [
      ...visible.where(
        (conversation) =>
            _acgoConversationPrefs[conversation.id]?.pinned == true,
      ),
      ...visible.where(
        (conversation) =>
            _acgoConversationPrefs[conversation.id]?.pinned != true,
      ),
    ];
  }

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
    final storage = await _currentStorage();
    await storage.setString(_prefDisplayName, _nameController.text.trim());
    await storage.setBool(_prefOobeDone, true);
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
    _messagesByRoom.putIfAbsent(roomId, () => []).add(message);
    _messagesVersion.value++;
    if (roomId != _lobbyRoomId) {
      _scheduleMessagesSave(roomId);
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
      _messagesScrollController.jumpTo(
        _messagesScrollController.position.maxScrollExtent,
      );
    });
  }

  void _scan() {
    setState(() => _scanning = true);
    unawaited(_startDiscoverySafely());
    _scanTimer?.cancel();
    _scanTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _scanning = false);
      }
    });
  }

  Future<void> _startDiscoverySafely() async {
    try {
      await _network.startDiscovery();
    } catch (e) {
      if (mounted) {
        setState(() => _error = '局域网发现不可用：$e');
      }
    }
  }

  Future<void> _createRoom() async {
    final name = _roomController.text.trim();
    if (name.isEmpty) return;
    try {
      final room = await _network.hostRoom(name: name, relay: _relayEnabled);
      setState(() {
        _activeRoom = room;
        _activeAcgoConversation = null;
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
      setState(() {
        _activeRoom = room;
        _activeAcgoConversation = null;
        _error = '正在连接 ${room.name}...';
      });
      _resetMessageWindow(room.id);
      await Future<void>.delayed(Duration.zero);
      await _network.joinRoom(
        room,
        displayName: _nameController.text.trim(),
        relay: _relayEnabled,
      );
      setState(() {
        _activeRoom = room;
        _activeAcgoConversation = null;
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
    if (text.isEmpty) return;
    if (_activeAcgoConversation != null) {
      await _sendAcgoMessage(text);
      return;
    }
    if (_activeRoom == null) return;
    _messageController.clear();
    Timer.run(() => unawaited(_sendTextInBackground(text)));
  }

  Future<void> _sendTextInBackground(String text) async {
    try {
      await _network.send(text, sender: _nameController.text.trim());
    } catch (e) {
      if (mounted) {
        setState(() => _error = '发送失败：$e');
      }
    }
  }

  Future<void> _loadAcgoConversations() async {
    final service = _acgoPrivateService;
    if (service == null || _loadingAcgoConversations) return;
    setState(() {
      _loadingAcgoConversations = true;
      _error = null;
    });
    try {
      final conversations = <AcgoPrivateConversation>[];
      final seen = <String>{};
      var cursor = '0';
      for (var page = 0; page < 50; page++) {
        final pageConversations = await service.listConversations(
          lastUserConversations: cursor,
        );
        final before = seen.length;
        for (final conversation in pageConversations) {
          if (seen.add(conversation.id)) {
            conversations.add(conversation);
          }
        }
        if (pageConversations.isEmpty || seen.length == before) {
          break;
        }
        cursor = pageConversations.last.id;
      }
      if (!mounted) return;
      setState(() {
        _acgoConversations = conversations;
        _loadingAcgoConversations = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingAcgoConversations = false;
        _error = '加载 ACGO 私信失败：$e';
      });
    }
  }

  Future<void> _openAcgoConversation(
    AcgoPrivateConversation conversation,
  ) async {
    setState(() {
      _activeAcgoConversation = conversation;
      _activeRoom = null;
      _error = null;
    });
    _resetMessageWindow(_acgoRoomId(conversation.id));
    unawaited(_ensureAcgoE2eeAdvertised(conversation));
    await _loadAcgoMessages(conversation);
  }

  Future<void> _loadAcgoMessages(AcgoPrivateConversation conversation) async {
    final service = _acgoPrivateService;
    if (service == null || _loadingAcgoMessages) return;
    setState(() => _loadingAcgoMessages = true);
    try {
      final messages = <AcgoPrivateMessage>[];
      final seen = <String>{};
      var cursor = '0';
      for (var page = 0; page < 50; page++) {
        final pageMessages = await service.listMessages(
          conversation,
          messageId: cursor,
        );
        final before = seen.length;
        for (final message in pageMessages) {
          if (seen.add(message.id)) {
            messages.add(message);
          }
        }
        if (pageMessages.isEmpty || seen.length == before) {
          break;
        }
        cursor = pageMessages.last.id;
      }
      if (!mounted) return;
      final chatMessages = <ChatMessage>[];
      final peerKeyCountBefore = _acgoPeerKeys.length;
      for (final message in messages) {
        final chatMessage = _chatMessageFromAcgoMessage(message, conversation);
        if (chatMessage != null) {
          chatMessages.add(chatMessage);
        }
      }
      if (_acgoPeerKeys.length != peerKeyCountBefore) {
        unawaited(_saveAcgoPeerKeys());
      }
      setState(() {
        _acgoMessagesByConversation[conversation.id] = chatMessages;
        _loadingAcgoMessages = false;
      });
      _scrollMessagesToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingAcgoMessages = false;
        _error = '加载 ACGO 私信消息失败：$e';
      });
    }
  }

  Future<void> _sendAcgoMessage(String text) async {
    final service = _acgoPrivateService;
    final conversation = _activeAcgoConversation;
    if (service == null || conversation == null || _sendingAcgoMessage) return;
    _messageController.clear();
    setState(() => _sendingAcgoMessage = true);
    try {
      await _ensureAcgoE2eeAdvertised(conversation);
      final peerKey = _acgoPeerKeys[conversation.receiverId];
      final identity = _acgoE2eeIdentity;
      final encrypted = peerKey != null && identity != null;
      final outgoingText = encrypted
          ? AcgoE2ee.encryptText(
              text,
              peerKey,
              selfPublicKey: identity.publicKey,
            )
          : text;
      await service.sendText(conversation: conversation, text: outgoingText);
      if (!mounted) return;
      final message = ChatMessage(
        sender: _nameController.text.trim().isEmpty
            ? '我'
            : _nameController.text.trim(),
        text: text,
        roomId: _acgoRoomId(conversation.id),
        senderSignature: _signatureController.text.trim(),
        senderBirthday: _birthday,
        senderAvatarData: _avatarData,
        senderAcgoInfo: _acgoProfile?.encode(),
      );
      setState(() {
        _acgoMessagesByConversation
            .putIfAbsent(conversation.id, () => [])
            .add(message);
        _sendingAcgoMessage = false;
      });
      _scrollMessagesToBottom();
      unawaited(_loadAcgoConversations());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _sendingAcgoMessage = false;
        _error = '发送 ACGO 私信失败：$e';
      });
    }
  }

  Future<void> _showNewAcgoConversationDialog() async {
    _acgoReceiverController.clear();
    final receiverId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建 ACGO 私信'),
        content: TextField(
          controller: _acgoReceiverController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '对方 UID',
            prefixIcon: Icon(Icons.alternate_email),
          ),
          onSubmitted: (value) => Navigator.pop(context, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, _acgoReceiverController.text.trim()),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    if (receiverId == null || receiverId.isEmpty) return;
    AcgoPrivateConversation? existing;
    for (final conversation in _acgoConversations) {
      if (conversation.receiverId == receiverId) {
        existing = conversation;
        break;
      }
    }
    final conversation =
        existing ??
        AcgoPrivateConversation(
          id: receiverId,
          receiverId: receiverId,
          title: 'UID $receiverId',
        );
    if (existing == null) {
      setState(() {
        _acgoConversations = [conversation, ..._acgoConversations];
        _acgoConversationPrefs[conversation.id] =
            (_acgoConversationPrefs[conversation.id] ?? const _RoomPrefs())
                .copyWith(hidden: false);
      });
      unawaited(_saveAcgoConversationPrefs());
    } else if (_acgoConversationPrefs[existing.id]?.hidden == true) {
      final existingId = existing.id;
      setState(() {
        _acgoConversationPrefs[existingId] = _acgoConversationPrefs[existingId]!
            .copyWith(hidden: false);
      });
      unawaited(_saveAcgoConversationPrefs());
    }
    await _openAcgoConversation(conversation);
  }

  Future<void> _handleAcgoConversationAction(
    AcgoPrivateConversation conversation,
    _AcgoConversationAction action,
  ) async {
    final prefs = _acgoConversationPrefs[conversation.id] ?? const _RoomPrefs();
    if (action == _AcgoConversationAction.pin) {
      setState(() {
        _acgoConversationPrefs[conversation.id] = prefs.copyWith(
          pinned: !prefs.pinned,
        );
      });
      unawaited(_saveAcgoConversationPrefs());
    } else if (action == _AcgoConversationAction.delete) {
      setState(() {
        _acgoConversationPrefs[conversation.id] = prefs.copyWith(
          hidden: true,
          pinned: false,
        );
        _acgoMessagesByConversation.remove(conversation.id);
        if (_activeAcgoConversation?.id == conversation.id) {
          _activeAcgoConversation = null;
        }
      });
      unawaited(_saveAcgoConversationPrefs());
    }
  }

  Future<void> _showAcgoConversationContextMenu(
    AcgoPrivateConversation conversation,
    Offset position,
  ) async {
    final prefs = _acgoConversationPrefs[conversation.id] ?? const _RoomPrefs();
    final action = await showMenu<_AcgoConversationAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        PopupMenuItem(
          value: _AcgoConversationAction.pin,
          child: Row(
            children: [
              Icon(prefs.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              const SizedBox(width: 10),
              Text(prefs.pinned ? '取消置顶' : '置顶'),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _AcgoConversationAction.delete,
          child: Row(
            children: [
              Icon(Icons.delete_outline, color: Colors.red),
              SizedBox(width: 10),
              Text('删除私信', style: TextStyle(color: Colors.red)),
            ],
          ),
        ),
      ],
    );
    if (action != null) {
      await _handleAcgoConversationAction(conversation, action);
    }
  }

  Future<void> _ensureAcgoE2eeAdvertised(
    AcgoPrivateConversation conversation,
  ) async {
    final service = _acgoPrivateService;
    final identity = _acgoE2eeIdentity;
    if (service == null || identity == null) return;
    if (!_advertisedAcgoKeyConversations.add(conversation.id)) return;
    await service.sendText(
      conversation: conversation,
      text: AcgoE2ee.keyAdvertText(identity.publicKey),
    );
  }

  ChatMessage? _chatMessageFromAcgoMessage(
    AcgoPrivateMessage message,
    AcgoPrivateConversation conversation,
  ) {
    final key = AcgoE2ee.tryReadKeyAdvert(message.text);
    if (key != null && !message.mine) {
      _acgoPeerKeys[conversation.receiverId] = key;
      return null;
    }
    if (AcgoE2ee.isKeyAdvert(message.text)) {
      return null;
    }

    var text = message.text;
    final identity = _acgoE2eeIdentity;
    if (AcgoE2ee.isEncryptedMessage(text)) {
      final decrypted = identity == null
          ? null
          : AcgoE2ee.tryDecryptText(text, identity.privateKey);
      text = decrypted ?? '无法解密的 FastChat 加密消息';
    }

    return ChatMessage(
      sender: message.mine
          ? (_nameController.text.trim().isEmpty
                ? '我'
                : _nameController.text.trim())
          : message.senderName,
      text: text,
      roomId: _acgoRoomId(message.conversationId),
      senderSignature: message.mine ? _signatureController.text.trim() : null,
      senderBirthday: message.mine ? _birthday : null,
      senderAvatarData: message.mine ? _avatarData : null,
      senderAcgoInfo: message.mine ? _acgoProfile?.encode() : null,
    );
  }

  String _acgoRoomId(String conversationId) => 'acgo:$conversationId';

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
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent || _activeRoom == null) {
      return false;
    }
    final isPasteShortcut =
        event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed);
    if (!isPasteShortcut) {
      return false;
    }
    unawaited(_pasteClipboardAttachments());
    return true;
  }

  Future<void> _pasteClipboardAttachments() async {
    final roomId = _activeRoom?.id;
    if (roomId == null) {
      return;
    }
    try {
      final files = await Pasteboard.files();
      if (files.isNotEmpty) {
        var sent = false;
        for (final path in files) {
          final file = File(path);
          if (!await file.exists()) {
            continue;
          }
          final bytes = await file.readAsBytes();
          await _network.sendFile(
            sender: _nameController.text.trim(),
            fileName: _baseName(path),
            fileSize: bytes.length,
            base64Data: base64Encode(bytes),
          );
          sent = true;
        }
        if (sent) {
          return;
        }
      }

      final image = await Pasteboard.image;
      if (image == null || image.isEmpty) {
        return;
      }
      final fileName =
          'clipboard-image-${DateTime.now().millisecondsSinceEpoch}.png';
      await _network.sendFile(
        sender: _nameController.text.trim(),
        fileName: fileName,
        fileSize: image.length,
        base64Data: base64Encode(image),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = '粘贴附件失败：$e');
      }
    }
  }

  String _baseName(String path) {
    final normalized = path.replaceAll('\\', Platform.pathSeparator);
    return normalized.split(Platform.pathSeparator).last;
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
      setState(() {
        _activeRoom = room;
        _activeAcgoConversation = null;
        _error = '正在连接 ${room.name}...';
      });
      _resetMessageWindow(room.id);
      await Future<void>.delayed(Duration.zero);
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
        _activeAcgoConversation = null;
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
      if (_savedJoinedRooms.containsKey(room.id)) {
        await _hostSavedRoomTemporarily(room, e);
      } else {
        setState(() {
          _activeRoom = room;
          _error = '连接失败：$e';
        });
      }
    }
  }

  Future<void> _hostSavedRoomTemporarily(
    DiscoveredRoom room,
    Object connectError,
  ) async {
    try {
      final hostedRoom = await _network.hostRoom(
        name: room.name,
        relay: room.relay,
        roomId: room.id,
      );
      if (!mounted) return;
      setState(() {
        _activeRoom = hostedRoom;
        _activeAcgoConversation = null;
        _error = null;
      });
      _appendMessage(
        ChatMessage(
          sender: '系统',
          text: '保存的房间连接失败，已暂时由本机作为房主。',
          system: true,
          roomId: room.id,
        ),
      );
    } catch (hostError) {
      if (!mounted) return;
      setState(() {
        _activeRoom = room;
        _error = '连接失败：$connectError；临时开房失败：$hostError';
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
    final settingsSignatureController = TextEditingController(
      text: _signatureController.text,
    );
    var birthday = _birthday;
    var avatarData = _avatarData;
    var muted = _globalMuted;
    var acgoProfile = _acgoProfile;
    var downloadDirectory = _downloadDirectory;
    var portableMode = _portableMode;
    var portableRootDirectory = _portableRootDirectory;
    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('设置'),
          content: SingleChildScrollView(
            child: Column(
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
                TextField(
                  controller: settingsSignatureController,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: '个性签名',
                    prefixIcon: Icon(Icons.edit_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.cake_outlined),
                  title: const Text('出生日期'),
                  subtitle: Text(birthday.isEmpty ? '未填写' : birthday),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final initial = _parseBirthday(birthday) ?? DateTime(2000);
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: initial,
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) {
                      setDialogState(() {
                        birthday =
                            '${picked.year.toString().padLeft(4, '0')}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}';
                      });
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: _avatarWidget(
                    avatarData: avatarData,
                    name: settingsNameController.text.trim(),
                    radius: 18,
                  ),
                  title: const Text('头像'),
                  subtitle: Text(avatarData.isEmpty ? '未设置' : '已设置'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (avatarData.isNotEmpty)
                        IconButton(
                          tooltip: '清除头像',
                          onPressed: () =>
                              setDialogState(() => avatarData = ''),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      IconButton(
                        tooltip: '选择头像',
                        onPressed: () async {
                          final result = await FilePicker.pickFiles(
                            type: FileType.image,
                          );
                          final file = result?.files.single;
                          if (file == null) {
                            return;
                          }
                          final bytes = await file.readAsBytes();
                          final compactAvatar = await _avatarDataFromBytes(
                            bytes,
                          );
                          setDialogState(
                            () => avatarData = compactAvatar,
                          );
                        },
                        icon: const Icon(Icons.image_outlined),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('下载目录'),
                  subtitle: Text(
                    downloadDirectory.isEmpty
                        ? '默认：系统下载目录/FastChat'
                        : downloadDirectory,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (downloadDirectory.isNotEmpty)
                        IconButton(
                          tooltip: '恢复默认',
                          onPressed: () =>
                              setDialogState(() => downloadDirectory = ''),
                          icon: const Icon(Icons.restore),
                        ),
                      IconButton(
                        tooltip: '选择目录',
                        onPressed: () async {
                          final selected = await FilePicker.getDirectoryPath(
                            dialogTitle: '选择下载目录',
                            initialDirectory: downloadDirectory.isEmpty
                                ? null
                                : downloadDirectory,
                          );
                          if (selected == null || selected.isEmpty) return;
                          setDialogState(() => downloadDirectory = selected);
                        },
                        icon: const Icon(Icons.drive_folder_upload_outlined),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: portableMode,
                  onChanged: (value) async {
                    if (!value) {
                      setDialogState(() => portableMode = false);
                      return;
                    }
                    var selected = portableRootDirectory;
                    if (selected.isEmpty) {
                      selected =
                          await FilePicker.getDirectoryPath(
                            dialogTitle: '选择便携数据目录',
                          ) ??
                          '';
                    }
                    if (selected.isEmpty) return;
                    setDialogState(() {
                      portableMode = true;
                      portableRootDirectory = selected;
                    });
                  },
                  title: const Text('便携模式'),
                  subtitle: Text(
                    portableMode && portableRootDirectory.isNotEmpty
                        ? _portableDataDirectoryLabel(portableRootDirectory)
                        : '关闭时使用系统配置目录',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (portableMode)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.inventory_2_outlined),
                    title: const Text('便携数据目录'),
                    subtitle: Text(
                      portableRootDirectory.isEmpty
                          ? '未选择'
                          : _portableDataDirectoryLabel(portableRootDirectory),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: '选择目录',
                      onPressed: () async {
                        final selected = await FilePicker.getDirectoryPath(
                          dialogTitle: '选择便携数据目录',
                          initialDirectory: portableRootDirectory.isEmpty
                              ? null
                              : portableRootDirectory,
                        );
                        if (selected == null || selected.isEmpty) return;
                        setDialogState(() => portableRootDirectory = selected);
                      },
                      icon: const Icon(Icons.drive_folder_upload_outlined),
                    ),
                  ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.link_outlined),
                  title: const Text('ACGO 账号'),
                  subtitle: Text(
                    acgoProfile == null
                        ? '未绑定'
                        : '${acgoProfile!.displayName} · ${acgoProfile!.problemText}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Wrap(
                    spacing: 4,
                    children: [
                      if (acgoProfile != null)
                        IconButton(
                          tooltip: '刷新',
                          onPressed: () async {
                            final updated = await _refreshAcgoProfile();
                            if (updated != null) {
                              setDialogState(() => acgoProfile = updated);
                            }
                          },
                          icon: const Icon(Icons.refresh),
                        ),
                      if (acgoProfile != null)
                        IconButton(
                          tooltip: '解绑',
                          onPressed: () async {
                            await _clearAcgoBinding();
                            setDialogState(() => acgoProfile = null);
                          },
                          icon: const Icon(Icons.link_off_outlined),
                        )
                      else
                        IconButton(
                          tooltip: '绑定',
                          onPressed: () async {
                            final bound = await _showAcgoBindDialog();
                            if (bound != null) {
                              setDialogState(() => acgoProfile = bound);
                            }
                          },
                          icon: const Icon(Icons.login),
                        ),
                    ],
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
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final navigator = Navigator.of(context);
                final bootstrapPrefs = await SharedPreferences.getInstance();
                if (portableMode && portableRootDirectory.trim().isEmpty) {
                  final selected = await FilePicker.getDirectoryPath(
                    dialogTitle: '选择便携数据目录',
                  );
                  if (selected == null || selected.isEmpty) return;
                  portableRootDirectory = selected;
                }
                await bootstrapPrefs.setBool(_prefPortableMode, portableMode);
                if (portableMode) {
                  await bootstrapPrefs.setString(
                    _prefPortableRootDirectory,
                    portableRootDirectory.trim(),
                  );
                } else {
                  await bootstrapPrefs.remove(_prefPortableRootDirectory);
                }
                final targetStorage = _createStorage(
                  bootstrapPrefs,
                  portableMode: portableMode,
                  portableRootDirectory: portableRootDirectory,
                );
                _storage = targetStorage;
                final name = settingsNameController.text.trim();
                if (name.isNotEmpty) {
                  _nameController.text = name;
                }
                final signature = settingsSignatureController.text.trim();
                _signatureController.text = signature;
                await _saveSnapshotToStorage(
                  targetStorage,
                  displayName: name,
                  signature: signature,
                  birthday: birthday,
                  avatarData: avatarData,
                  downloadDirectory: downloadDirectory,
                  globalMuted: muted,
                  acgoProfile: acgoProfile,
                  acgoAccessToken: _acgoAccessToken,
                  oobeDone: true,
                );
                if (!mounted) {
                  return;
                }
                setState(() {
                  _birthday = birthday;
                  _avatarData = avatarData;
                  _downloadDirectory = downloadDirectory;
                  _portableMode = portableMode;
                  _portableRootDirectory = portableRootDirectory.trim();
                  _globalMuted = muted;
                  _acgoProfile = acgoProfile;
                });
                _network.updateProfile(
                  signature: signature,
                  birthday: birthday,
                  avatarData: avatarData,
                  acgoInfo: acgoProfile?.encode() ?? '',
                );
                if (navigator.mounted) {
                  navigator.pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    ).whenComplete(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        settingsNameController.dispose();
        settingsSignatureController.dispose();
      });
    });
  }

  Future<AcgoProfileSummary?> _showAcgoBindDialog() async {
    final accountController = TextEditingController();
    final passwordController = TextEditingController();
    var binding = false;
    String? error;
    try {
      return await showDialog<AcgoProfileSummary>(
        context: context,
        builder: (context) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('绑定 ACGO 账号'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: accountController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '账号 / 手机号 / 邮箱',
                    prefixIcon: Icon(Icons.account_circle_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: '密码',
                    prefixIcon: Icon(Icons.password_outlined),
                  ),
                  onSubmitted: (_) {
                    if (!binding) {
                      unawaited(
                        _bindAcgoFromDialog(
                          accountController.text,
                          passwordController.text,
                          Navigator.of(context),
                          setDialogState,
                          (value) => error = value,
                          (value) => binding = value,
                        ),
                      );
                    }
                  },
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: TextStyle(color: Colors.red.shade700)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: binding ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: binding
                    ? null
                    : () {
                        unawaited(
                          _bindAcgoFromDialog(
                            accountController.text,
                            passwordController.text,
                            Navigator.of(context),
                            setDialogState,
                            (value) => error = value,
                            (value) => binding = value,
                          ),
                        );
                      },
                child: binding
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('绑定'),
              ),
            ],
          ),
        ),
      );
    } finally {
      accountController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> _bindAcgoFromDialog(
    String account,
    String password,
    NavigatorState navigator,
    void Function(void Function()) setDialogState,
    void Function(String?) setError,
    void Function(bool) setBinding,
  ) async {
    account = account.trim();
    if (account.isEmpty || password.isEmpty) {
      setDialogState(() => setError('请输入账号和密码'));
      return;
    }
    setDialogState(() {
      setError(null);
      setBinding(true);
    });
    try {
      final result = await _acgoService.bindWithPassword(
        account: account,
        password: password,
      );
      await _saveAcgoBinding(result.summary, result.accessToken ?? '');
      if (navigator.mounted) {
        navigator.pop(result.summary);
      }
    } catch (e) {
      setDialogState(() {
        setError('绑定失败：$e');
        setBinding(false);
      });
    }
  }

  Future<AcgoProfileSummary?> _refreshAcgoProfile() async {
    final profile = _acgoProfile;
    if (profile == null || _acgoAccessToken.isEmpty) {
      return null;
    }
    try {
      final updated = await _acgoService.refresh(
        account: profile.account,
        accessToken: _acgoAccessToken,
        fallback: profile,
      );
      await _saveAcgoBinding(updated, _acgoAccessToken);
      return updated;
    } catch (e) {
      if (mounted) {
        setState(() => _error = '刷新 ACGO 信息失败：$e');
      }
      return null;
    }
  }

  Future<void> _saveAcgoBinding(
    AcgoProfileSummary profile,
    String accessToken,
  ) async {
    final storage = await _currentStorage();
    await storage.setString(_prefAcgoProfile, profile.encode());
    if (accessToken.isNotEmpty) {
      await storage.setString(_prefAcgoAccessToken, accessToken);
    }
    if (!mounted) return;
    final resolvedToken = accessToken.isNotEmpty
        ? accessToken
        : _acgoAccessToken;
    final existingService = _acgoPrivateService;
    setState(() {
      _acgoProfile = profile;
      _acgoAccessToken = resolvedToken;
      _acgoPrivateService = _createAcgoPrivateService(resolvedToken, profile);
    });
    existingService?.close();
    if (resolvedToken.isNotEmpty) {
      unawaited(_loadAcgoConversations());
    }
    _network.updateProfile(
      signature: _signatureController.text.trim(),
      birthday: _birthday,
      avatarData: _avatarData,
      acgoInfo: profile.encode(),
    );
  }

  Future<void> _clearAcgoBinding() async {
    final storage = await _currentStorage();
    await storage.remove(_prefAcgoProfile);
    await storage.remove(_prefAcgoAccessToken);
    if (!mounted) return;
    final existingService = _acgoPrivateService;
    setState(() {
      _acgoProfile = null;
      _acgoAccessToken = '';
      _acgoPrivateService = null;
      _acgoConversations = [];
      _acgoMessagesByConversation.clear();
      _activeAcgoConversation = null;
    });
    existingService?.close();
    _network.updateProfile(
      signature: _signatureController.text.trim(),
      birthday: _birthday,
      avatarData: _avatarData,
      acgoInfo: '',
    );
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

  DateTime? _parseBirthday(String value) {
    if (value.trim().isEmpty) {
      return null;
    }
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }

  int? _ageFromBirthday(String value) {
    final birthday = _parseBirthday(value);
    if (birthday == null) {
      return null;
    }
    final now = DateTime.now();
    var age = now.year - birthday.year;
    if (now.month < birthday.month ||
        (now.month == birthday.month && now.day < birthday.day)) {
      age--;
    }
    return age < 0 ? null : age;
  }

  bool _isBirthdaySoon(String value) {
    final birthday = _parseBirthday(value);
    if (birthday == null) {
      return false;
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    var nextBirthday = DateTime(now.year, birthday.month, birthday.day);
    if (nextBirthday.isBefore(today)) {
      nextBirthday = DateTime(now.year + 1, birthday.month, birthday.day);
    }
    final days = nextBirthday.difference(today).inDays;
    return days >= 0 && days <= 10;
  }

  String _displaySender(ChatMessage message) {
    final prefix = _isBirthdaySoon(message.senderBirthday ?? '') ? '🎂 ' : '';
    return '$prefix${message.sender}';
  }

  Widget _avatarWidget({
    required String? avatarData,
    required String name,
    required double radius,
  }) {
    final data = avatarData == null || avatarData.isEmpty ? null : avatarData;
    if (data != null) {
      try {
        final image = _cachedAvatarImage(data);
        return CircleAvatar(
          radius: radius,
          backgroundImage: image,
        );
      } catch (_) {}
    }
    return CircleAvatar(
      radius: radius,
      backgroundColor: const Color(0xffcce7df),
      foregroundColor: const Color(0xff176b5b),
      child: Text(
        name.trim().isEmpty ? '?' : name.trim().characters.first,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }

  MemoryImage _cachedAvatarImage(String encoded) {
    final cached = _avatarImageCache[encoded];
    if (cached != null) return cached;
    final image = MemoryImage(base64Decode(encoded));
    if (_avatarImageCache.length >= 64) {
      _avatarImageCache.remove(_avatarImageCache.keys.first);
    }
    _avatarImageCache[encoded] = image;
    return image;
  }

  void _showUserInfo(ChatMessage message) {
    final birthday = message.senderBirthday ?? '';
    final age = _ageFromBirthday(birthday);
    final acgoProfile = AcgoProfileSummary.tryDecode(message.senderAcgoInfo);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            _avatarWidget(
              avatarData: message.senderAvatarData,
              name: message.sender,
              radius: 22,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(_displaySender(message))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _UserInfoLine(
              label: '个性签名',
              value: (message.senderSignature ?? '').isEmpty
                  ? '未填写'
                  : message.senderSignature!,
            ),
            const SizedBox(height: 10),
            _UserInfoLine(
              label: '出生日期',
              value: birthday.isEmpty ? '未填写' : birthday,
            ),
            const SizedBox(height: 10),
            _UserInfoLine(label: '年龄', value: age == null ? '未知' : '$age 岁'),
            const SizedBox(height: 10),
            if (acgoProfile == null)
              const _UserInfoLine(label: 'ACGO 账号', value: '未绑定')
            else ...[
              _UserInfoLine(label: 'ACGO 账号', value: acgoProfile.displayName),
              const SizedBox(height: 10),
              _UserInfoLine(label: '刷题信息', value: acgoProfile.problemText),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
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
              return _avatarWidget(
                avatarData: _avatarData,
                name: name,
                radius: 16,
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
          child: ListView(
            children: [
              _buildAcgoPrivateSection(),
              if (_hostedRooms.isNotEmpty)
                _roomSection(
                  title: '我创建的房间',
                  rooms: _orderedRooms(_hostedRooms),
                  tileBuilder: (room) => _roomTile(
                    room,
                    onTap: () => _openRoom(room),
                    onSecondaryTapDown: (details) =>
                        _showRoomContextMenu(room, details.globalPosition),
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
                    onSecondaryTapDown: (details) =>
                        _showRoomContextMenu(room, details.globalPosition),
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
                    onSecondaryTapDown: (details) =>
                        _showRoomContextMenu(room, details.globalPosition),
                  ),
                ),
              if (_hostedRooms.isEmpty &&
                  _visibleSavedJoinedRooms.isEmpty &&
                  _visibleDiscoveredRooms.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  child: Text(
                    '暂未发现局域网房间\n点击上方创建一个',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey.shade600, height: 1.6),
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

  Widget _buildAcgoPrivateSection() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'ACGO 私信',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              if (_loadingAcgoConversations)
                const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              IconButton(
                tooltip: '刷新 ACGO 私信',
                visualDensity: VisualDensity.compact,
                onPressed: _acgoPrivateService == null
                    ? null
                    : _loadAcgoConversations,
                icon: const Icon(Icons.refresh, size: 18),
              ),
              IconButton(
                tooltip: '新建 ACGO 私信',
                visualDensity: VisualDensity.compact,
                onPressed: _acgoPrivateService == null
                    ? null
                    : _showNewAcgoConversationDialog,
                icon: const Icon(Icons.add_comment_outlined, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_acgoPrivateService == null)
            Text(
              '绑定 ACGO 账号后可使用私信',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            )
          else if (_visibleAcgoConversations.isEmpty &&
              !_loadingAcgoConversations)
            Text(
              '暂无私信会话',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            )
          else
            ..._visibleAcgoConversations.map(
              (conversation) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _acgoConversationTile(conversation),
              ),
            ),
        ],
      ),
    );
  }

  Widget _acgoConversationTile(AcgoPrivateConversation conversation) {
    final selected = _activeAcgoConversation?.id == conversation.id;
    final prefs = _acgoConversationPrefs[conversation.id] ?? const _RoomPrefs();
    return InkWell(
      onTap: () => _openAcgoConversation(conversation),
      onSecondaryTapDown: (details) => _showAcgoConversationContextMenu(
        conversation,
        details.globalPosition,
      ),
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
            const CircleAvatar(
              backgroundColor: Color(0xffe6f0ff),
              foregroundColor: Color(0xff2457a6),
              child: Icon(Icons.alternate_email, size: 18),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    conversation.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    conversation.lastMessage?.isNotEmpty == true
                        ? conversation.lastMessage!
                        : 'UID ${conversation.receiverId}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ),
            if (conversation.unread > 0)
              Container(
                margin: const EdgeInsets.only(left: 8),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xff176b5b),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  conversation.unread > 99 ? '99+' : '${conversation.unread}',
                  style: const TextStyle(color: Colors.white, fontSize: 11),
                ),
              )
            else ...[
              if (prefs.pinned)
                const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(
                    Icons.push_pin,
                    size: 15,
                    color: Color(0xff176b5b),
                  ),
                ),
              const Icon(Icons.chevron_right, size: 18, color: Colors.black38),
            ],
          ],
        ),
      ),
    );
  }

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
    final acgoConversation = _activeAcgoConversation;
    final messageListKey = _activeMessageListKey;
    final canChat = _activeRoom != null || acgoConversation != null;
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
                acgoConversation != null
                    ? Icons.alternate_email
                    : (_activeRoom == null
                          ? Icons.chat_bubble_outline
                          : Icons.lock_outline),
                color: const Color(0xff176b5b),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    acgoConversation?.title ?? _activeRoom?.name ?? '选择一个聊天室',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    acgoConversation != null
                        ? (_loadingAcgoMessages
                              ? '正在加载 ACGO 私信'
                              : 'ACGO 私信 · UID ${acgoConversation.receiverId}')
                        : (_activeRoom == null
                              ? '消息仅在局域网内传输'
                              : '${_activeRoom!.peers} 位成员在线'),
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
              if (acgoConversation != null)
                IconButton(
                  tooltip: '刷新私信',
                  onPressed: () => _loadAcgoMessages(acgoConversation),
                  icon: const Icon(Icons.refresh, size: 20),
                ),
            ],
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<int>(
            valueListenable: _messagesVersion,
            builder: (context, _, _) => _buildMessagesList(messageListKey),
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
                    if (canChat) {
                      _send();
                    }
                    return null;
                  },
                ),
                InsertNewlineIntent: CallbackAction<InsertNewlineIntent>(
                  onInvoke: (_) {
                    if (canChat) {
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
                      enabled: canChat && !_sendingAcgoMessage,
                      controller: _messageController,
                      minLines: 1,
                      maxLines: 4,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: canChat
                            ? '输入消息，Enter 发送，Shift+Enter 换行'
                            : '加入房间或选择 ACGO 私信后开始聊天',
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
                    onPressed:
                        _activeRoom == null || _activeAcgoConversation != null
                        ? null
                        : _sendFile,
                    icon: const Icon(Icons.attach_file),
                  ),
                  IconButton.filled(
                    tooltip: '发送',
                    onPressed: canChat && !_sendingAcgoMessage ? _send : null,
                    icon: _sendingAcgoMessage
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
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

  Widget _buildMessagesList(String messageListKey) {
    final allMessages = messageListKey.startsWith('acgo:')
        ? (_activeAcgoConversation == null
              ? const <ChatMessage>[]
              : _acgoMessagesByConversation[_activeAcgoConversation!.id] ??
                    const <ChatMessage>[])
        : _messagesForRoom(messageListKey);
    if (allMessages.isEmpty) {
      return const SizedBox();
    }
    final visibleMessages = _windowedMessages(messageListKey, allMessages);
    final hiddenMessageCount = allMessages.length - visibleMessages.length;
    return ListView.builder(
      key: ValueKey(messageListKey),
      controller: _messagesScrollController,
      padding: const EdgeInsets.all(24),
      itemCount: visibleMessages.length + 1,
      itemBuilder: (_, i) {
        if (i == 0) {
          return _olderMessagesHint(hiddenMessageCount);
        }
        return _messageBubble(visibleMessages[i - 1]);
      },
    );
  }

  Widget _olderMessagesHint(int hiddenMessageCount) {
    if (hiddenMessageCount <= 0) {
      return const SizedBox(height: 8);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Center(
        child: Text(
          '向上滚动加载更早的 $hiddenMessageCount 条消息',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
        ),
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
            InkWell(
              onTap: () => _showUserInfo(message),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _avatarWidget(
                      avatarData: message.senderAvatarData,
                      name: message.sender,
                      radius: 12,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      _displaySender(message),
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xff176b5b),
                      ),
                    ),
                  ],
                ),
              ),
            ),
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
    final isImage = _isImageFile(message.fileName);
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
        child: isImage
            ? _imageTileContent(message, size)
            : Row(
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
                              ? '点击保存并打开文件夹 · $size'
                              : '点击保存 · $size',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  bool _isImageFile(String? fileName) {
    final lower = (fileName ?? '').toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp');
  }

  Widget _imageTileContent(ChatMessage message, String size) {
    final bytes = _cachedImageBytes(message.fileData ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            bytes,
            width: 240,
            height: 160,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '${message.fileName ?? '图片'} · $size',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 2),
        Text(
          Compatibility.canOpenSavedFiles ? '点击保存并打开文件夹' : '点击保存',
          style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
        ),
      ],
    );
  }

  Uint8List _cachedImageBytes(String encoded) {
    final cached = _imageBytesCache[encoded];
    if (cached != null) return cached;
    final bytes = base64Decode(encoded);
    if (_imageBytesCache.length >= 32) {
      _imageBytesCache.remove(_imageBytesCache.keys.first);
    }
    _imageBytesCache[encoded] = bytes;
    return bytes;
  }

  Future<void> _saveAndOpenFile(ChatMessage message) async {
    final fileName = message.fileName;
    final fileData = message.fileData;
    if (fileName == null || fileData == null) {
      return;
    }
    try {
      final receivedDir = await _resolvedDownloadDirectory();
      if (!await receivedDir.exists()) {
        await receivedDir.create(recursive: true);
      }
      final file = File(
        '${receivedDir.path}${Platform.pathSeparator}$fileName',
      );
      await file.writeAsBytes(base64Decode(fileData));
      if (Compatibility.canOpenSavedFiles) {
        await _openContainingFolder(file, receivedDir);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '保存文件失败：$e');
      }
    }
  }

  Future<Directory> _resolvedDownloadDirectory() async {
    if (_downloadDirectory.trim().isNotEmpty) {
      return Directory(_downloadDirectory.trim());
    }
    final baseDir =
        await getDownloadsDirectory() ??
        await getApplicationDocumentsDirectory();
    return Directory('${baseDir.path}${Platform.pathSeparator}FastChat');
  }

  Future<void> _openContainingFolder(File file, Directory directory) async {
    try {
      if (Platform.isWindows) {
        final result = await Process.run('explorer.exe', [
          '/select,${file.path}',
        ]);
        if (result.exitCode == 0) return;
      } else if (Platform.isMacOS) {
        final result = await Process.run('open', ['-R', file.path]);
        if (result.exitCode == 0) return;
      } else if (Platform.isLinux) {
        final result = await Process.run('xdg-open', [directory.path]);
        if (result.exitCode == 0) return;
      }
      await OpenFile.open(directory.path);
    } catch (_) {
      try {
        await OpenFile.open(directory.path);
      } catch (_) {}
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

class _UserInfoLine extends StatelessWidget {
  const _UserInfoLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
        ),
        const SizedBox(height: 3),
        SelectableText(
          value,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}
