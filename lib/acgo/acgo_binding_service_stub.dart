import 'dart:convert';

class AcgoProfileSummary {
  const AcgoProfileSummary({
    required this.account,
    this.userId,
    this.nickname,
    this.accepted,
    this.submitted,
    this.ranking,
    this.rating,
    this.level,
    this.raw,
    this.updatedAt,
  });

  final String account;
  final String? userId;
  final String? nickname;
  final int? accepted;
  final int? submitted;
  final int? ranking;
  final int? rating;
  final String? level;
  final Map<String, dynamic>? raw;
  final DateTime? updatedAt;

  String get displayName {
    final name = nickname?.trim();
    if (name != null && name.isNotEmpty) return name;
    if (userId != null && userId!.isNotEmpty) return 'UID $userId';
    return account;
  }

  String get problemText {
    final values = <String>[];
    if (accepted != null) values.add('通过 $accepted');
    if (submitted != null) values.add('提交 $submitted');
    if (ranking != null) values.add('排名 $ranking');
    if (rating != null) values.add('Rating $rating');
    if (level != null && level!.isNotEmpty) values.add(level!);
    return values.isEmpty ? '暂无刷题统计' : values.join(' / ');
  }

  Map<String, dynamic> toJson() => {
    'account': account,
    'userId': userId,
    'nickname': nickname,
    'accepted': accepted,
    'submitted': submitted,
    'ranking': ranking,
    'rating': rating,
    'level': level,
    'raw': raw,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  String encode() => jsonEncode(toJson());

  static AcgoProfileSummary? tryDecode(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) return null;
      return AcgoProfileSummary.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }

  static AcgoProfileSummary fromJson(Map<String, dynamic> json) {
    final raw = json['raw'];
    return AcgoProfileSummary(
      account: json['account']?.toString() ?? '',
      userId: json['userId']?.toString(),
      nickname: json['nickname']?.toString(),
      accepted: _intValue(json['accepted']),
      submitted: _intValue(json['submitted']),
      ranking: _intValue(json['ranking']),
      rating: _intValue(json['rating']),
      level: json['level']?.toString(),
      raw: raw is Map ? Map<String, dynamic>.from(raw) : null,
      updatedAt: DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }

  static int? _intValue(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

class AcgoBindingResult {
  const AcgoBindingResult({required this.summary, required this.accessToken});

  final AcgoProfileSummary summary;
  final String? accessToken;
}

class AcgoBindingService {
  Future<AcgoBindingResult> bindWithPassword({
    required String account,
    required String password,
  }) async {
    throw UnsupportedError('当前平台不支持 ACGO 账号绑定。');
  }

  Future<AcgoProfileSummary> refresh({
    required String account,
    required String accessToken,
    AcgoProfileSummary? fallback,
  }) async {
    throw UnsupportedError('当前平台不支持 ACGO 账号绑定。');
  }
}
