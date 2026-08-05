class AcgoPrivateConversation {
  const AcgoPrivateConversation({
    required this.id,
    required this.receiverId,
    required this.title,
    this.lastMessage,
    this.unread = 0,
  });

  final String id;
  final String receiverId;
  final String title;
  final String? lastMessage;
  final int unread;
}

class AcgoPrivateMessage {
  const AcgoPrivateMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.text,
    required this.mine,
    this.time,
  });

  final String id;
  final String conversationId;
  final String senderId;
  final String senderName;
  final String text;
  final bool mine;
  final DateTime? time;
}

class AcgoPrivateMessageService {
  AcgoPrivateMessageService({required String accessToken, String? myUserId});

  Future<List<AcgoPrivateConversation>> listConversations({
    String lastUserConversations = '0',
  }) async {
    throw UnsupportedError('当前平台不支持 ACGO 私信。');
  }

  Future<List<AcgoPrivateMessage>> listMessages(
    AcgoPrivateConversation conversation, {
    String messageId = '0',
  }) async {
    throw UnsupportedError('当前平台不支持 ACGO 私信。');
  }

  Future<void> sendText({
    required AcgoPrivateConversation conversation,
    required String text,
  }) async {
    throw UnsupportedError('当前平台不支持 ACGO 私信。');
  }

  void close() {}
}
