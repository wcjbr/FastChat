import 'package:acgo_sdk/acgo_sdk.dart';

import 'acgo_private_message_service_stub.dart';
export 'acgo_private_message_service_stub.dart'
    show AcgoPrivateConversation, AcgoPrivateMessage;

class AcgoPrivateMessageService {
  AcgoPrivateMessageService({required String accessToken, this._myUserId})
    : _client = AcgoClient(accessToken: accessToken) {
    _client.ssoAccessToken = accessToken;
  }

  final AcgoClient _client;
  final String? _myUserId;

  Future<List<AcgoPrivateConversation>> listConversations() async {
    final payload = await _client.listPrivateConversations();
    final items = _firstList(payload, ['list', 'records', 'items', 'data']);
    return items
        .whereType<Map>()
        .map((item) => _conversationFromMap(Map<String, Object?>.from(item)))
        .where((conversation) => conversation.receiverId.isNotEmpty)
        .toList();
  }

  Future<List<AcgoPrivateMessage>> listMessages(
    AcgoPrivateConversation conversation,
  ) async {
    final payload = await _client.listPrivateMessages(conversation.id);
    final items = _firstList(payload, ['list', 'records', 'items', 'data']);
    final messages = items
        .whereType<Map>()
        .map(
          (item) => _messageFromMap(
            Map<String, Object?>.from(item),
            conversation: conversation,
          ),
        )
        .where((message) => message.text.isNotEmpty)
        .toList();
    messages.sort((a, b) {
      final at = a.time;
      final bt = b.time;
      if (at == null || bt == null) return 0;
      return at.compareTo(bt);
    });
    return messages;
  }

  Future<void> sendText({
    required AcgoPrivateConversation conversation,
    required String text,
  }) => _client.sendPrivateText(conversation.receiverId, text);

  void close() {
    _client.close();
  }

  AcgoPrivateConversation _conversationFromMap(Map<String, Object?> item) {
    final user = _firstMap(item, ['user', 'receiver', 'targetUser']);
    final receiverId =
        _firstString(user, ['userId', 'id', 'uid']) ??
        _firstString(item, ['receiverId', 'receiveId', 'userId']) ??
        '';
    final id =
        _firstString(item, ['userConversationsId', 'conversationId', 'id']) ??
        receiverId;
    final title =
        _firstString(user, ['nickname', 'nickName', 'name', 'username']) ??
        _firstString(item, ['nickname', 'nickName', 'name', 'username']) ??
        (receiverId.isEmpty ? 'ACGO 用户' : 'UID $receiverId');
    return AcgoPrivateConversation(
      id: id,
      receiverId: receiverId,
      title: title,
      lastMessage: _firstString(item, [
        'lastMessage',
        'message',
        'content',
        'lastContent',
      ]),
      unread: _firstInt(item, ['unread', 'unReadCount', 'unreadCount']) ?? 0,
    );
  }

  AcgoPrivateMessage _messageFromMap(
    Map<String, Object?> item, {
    required AcgoPrivateConversation conversation,
  }) {
    final sender = _firstMap(item, ['sender', 'sendUser', 'user']);
    final senderId =
        _firstString(sender, ['userId', 'id', 'uid']) ??
        _firstString(item, ['sendId', 'senderId', 'userId']) ??
        '';
    final myUserId = _myUserId;
    final mine =
        item['isSelf'] == true ||
        item['mine'] == true ||
        (myUserId != null && myUserId.isNotEmpty && senderId == myUserId);
    final senderName = mine
        ? '我'
        : _firstString(sender, ['nickname', 'nickName', 'name', 'username']) ??
              conversation.title;
    return AcgoPrivateMessage(
      id:
          _firstString(item, ['messageId', 'id', 'key']) ??
          '${conversation.id}-${item.hashCode}',
      conversationId: conversation.id,
      senderId: senderId,
      senderName: senderName,
      text:
          _firstString(item, ['message', 'content', 'text', 'msg']) ??
          _firstString(_firstMap(item, ['body']), ['message', 'content']) ??
          '',
      mine: mine,
      time: _firstDate(item, [
        'time',
        'createTime',
        'createdAt',
        'sendTime',
        'timestamp',
      ]),
    );
  }

  List<Object?> _firstList(Object? value, List<String> keys) {
    if (value is List) return value;
    if (value is Map) {
      for (final key in keys) {
        final item = value[key];
        if (item is List) return item;
      }
      for (final item in value.values) {
        final found = _firstList(item, keys);
        if (found.isNotEmpty) return found;
      }
    }
    return const [];
  }

  Map<String, Object?>? _firstMap(
    Map<String, Object?>? value,
    List<String> keys,
  ) {
    if (value == null) return null;
    for (final key in keys) {
      final item = value[key];
      if (item is Map) return Map<String, Object?>.from(item);
    }
    return null;
  }

  String? _firstString(Map<String, Object?>? value, List<String> keys) {
    if (value == null) return null;
    for (final key in keys) {
      final item = value[key];
      if (item != null && item.toString().trim().isNotEmpty) {
        return item.toString();
      }
    }
    return null;
  }

  int? _firstInt(Map<String, Object?> value, List<String> keys) {
    for (final key in keys) {
      final item = value[key];
      if (item is int) return item;
      if (item is num) return item.toInt();
      final parsed = int.tryParse(item?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  DateTime? _firstDate(Map<String, Object?> value, List<String> keys) {
    for (final key in keys) {
      final item = value[key];
      if (item is int) {
        return DateTime.fromMillisecondsSinceEpoch(
          item > 100000000000 ? item : item * 1000,
        );
      }
      if (item is num) {
        final intValue = item.toInt();
        return DateTime.fromMillisecondsSinceEpoch(
          intValue > 100000000000 ? intValue : intValue * 1000,
        );
      }
      final parsed = DateTime.tryParse(item?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }
}
