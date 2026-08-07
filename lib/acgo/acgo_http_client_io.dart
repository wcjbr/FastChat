import 'dart:io';

import 'package:acgo_sdk/acgo_sdk.dart';

class FastChatAcgoHttp {
  const FastChatAcgoHttp._();

  static AcgoClient createClient({String? accessToken}) {
    return HttpOverrides.runWithHttpOverrides(
      () => AcgoClient(accessToken: accessToken),
      _AcgoHttpOverrides(),
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

class _AcgoHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.badCertificateCallback = (certificate, host, port) {
      return FastChatAcgoHttp._isAcgoHost(host);
    };
    return client;
  }
}
