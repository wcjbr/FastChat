import 'package:acgo_sdk/acgo_sdk.dart';

import 'acgo_binding_service_stub.dart';
export 'acgo_binding_service_stub.dart'
    show AcgoBindingResult, AcgoProfileSummary;

class AcgoBindingService {
  Future<AcgoBindingResult> bindWithPassword({
    required String account,
    required String password,
  }) async {
    final client = AcgoClient();
    try {
      final login = await client.loginByPassword(account, password);
      final summary = await _loadSummary(client, account, loginPayload: login);
      return AcgoBindingResult(
        summary: summary,
        accessToken: client.accessToken ?? client.ssoAccessToken,
      );
    } finally {
      client.close();
    }
  }

  Future<AcgoProfileSummary> refresh({
    required String account,
    required String accessToken,
    AcgoProfileSummary? fallback,
  }) async {
    final client = AcgoClient(accessToken: accessToken);
    client.ssoAccessToken = accessToken;
    try {
      return _loadSummary(client, account, fallback: fallback);
    } finally {
      client.close();
    }
  }

  Future<AcgoProfileSummary> _loadSummary(
    AcgoClient client,
    String account, {
    Object? loginPayload,
    AcgoProfileSummary? fallback,
  }) async {
    final payloads = <Object?>[loginPayload];
    for (final request in _profileRequests) {
      try {
        payloads.add(await request(client));
      } catch (_) {}
    }

    final merged = <String, dynamic>{};
    for (final payload in payloads) {
      _collectUsefulFields(payload, merged);
    }

    return AcgoProfileSummary(
      account: account,
      userId: _firstString(merged, ['userId', 'uid', 'id']) ?? fallback?.userId,
      nickname:
          _firstString(merged, ['nickname', 'nickName', 'name', 'username']) ??
          fallback?.nickname,
      accepted:
          _firstInt(merged, [
            'accepted',
            'acceptedCount',
            'acceptCount',
            'acCount',
            'solved',
            'solvedCount',
            'passed',
            'passCount',
            'finishQuestionCount',
          ]) ??
          fallback?.accepted,
      submitted:
          _firstInt(merged, [
            'submitted',
            'submitCount',
            'submissionCount',
            'totalSubmit',
            'totalSubmission',
          ]) ??
          fallback?.submitted,
      ranking:
          _firstInt(merged, ['ranking', 'rank', 'ratingRank', 'globalRank']) ??
          fallback?.ranking,
      rating:
          _firstInt(merged, ['rating', 'score', 'integral', 'points']) ??
          fallback?.rating,
      level:
          _firstString(merged, ['level', 'levelName', 'rankName', 'medal']) ??
          fallback?.level,
      raw: merged.isEmpty ? fallback?.raw : merged,
      updatedAt: DateTime.now(),
    );
  }

  static final List<Future<Object?> Function(AcgoClient)> _profileRequests = [
    (client) => client.get('/acgoAccount/openapi/oauth/v3/userInfo'),
    (client) => client.get('/acgoAccount/openapi/user/info'),
    (client) => client.get('/acgoAccount/api/user/info'),
    (client) => client.get('/acgoAccount/api/user/getUserInfo'),
    (client) => client.get('/acgoCourse/api/user/info'),
    (client) => client.get('/acgoCourse/api/user/statistics'),
    (client) => client.get('/acgoQuestion/api/user/statistics'),
    (client) => client.get('/acgoJudge/api/user/statistics'),
  ];

  void _collectUsefulFields(Object? value, Map<String, dynamic> out) {
    if (value is Map) {
      for (final entry in value.entries) {
        final key = entry.key.toString();
        final item = entry.value;
        if (item is String || item is num || item is bool) {
          out.putIfAbsent(key, () => item);
        }
        if (item is Map || item is List) {
          _collectUsefulFields(item, out);
        }
      }
    } else if (value is List) {
      for (final item in value) {
        _collectUsefulFields(item, out);
      }
    }
  }

  String? _firstString(Map<String, dynamic> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString();
      }
    }
    return null;
  }

  int? _firstInt(Map<String, dynamic> values, List<String> keys) {
    for (final key in keys) {
      final value = values[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      final parsed = int.tryParse(value?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }
}
