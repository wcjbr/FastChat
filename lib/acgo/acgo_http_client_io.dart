import 'package:acgo_sdk/acgo_sdk.dart';

class FastChatAcgoHttp {
  const FastChatAcgoHttp._();

  static AcgoClient createClient({String? accessToken}) {
    return AcgoClient(accessToken: accessToken);
  }
}
