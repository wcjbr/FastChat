import 'dart:io';

import 'package:acgo_sdk/acgo_sdk.dart';

class FastChatAcgoHttp {
  const FastChatAcgoHttp._();

  static AcgoClient createClient({String? accessToken}) {
    return HttpOverrides.runZoned(
      () => AcgoClient(accessToken: accessToken),
      createHttpClient: (context) {
        final client = HttpClient(context: context);
        client.badCertificateCallback = (certificate, host, port) {
          return _isAcgoHost(host);
        };
        return client;
      },
    );
  }

  static bool _isAcgoHost(String host) {
    final normalized = host.toLowerCase();
    return normalized == 'acgo.cn' ||
        normalized.endsWith('.acgo.cn') ||
        normalized == 'xiaomawang.com' ||
        normalized.endsWith('.xiaomawang.com');
  }
}
