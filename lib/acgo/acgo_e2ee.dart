import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class AcgoE2eeIdentity {
  const AcgoE2eeIdentity({required this.publicKey, required this.privateKey});

  final RSAPublicKey publicKey;
  final RSAPrivateKey privateKey;
}

class AcgoE2ee {
  AcgoE2ee._();

  static const keyPrefix = '[FastChat:E2EE-Key:v1]';
  static const messagePrefix = '[FastChat:E2EE:v1]';
  static const messagePartPrefix = '[FastChat:E2EE-Part:v1]';
  static const acgoEncryptedPartMaxLength = 450;

  static bool isProtocolText(String text) =>
      text.startsWith(keyPrefix) ||
      text.startsWith(messagePrefix) ||
      text.startsWith(messagePartPrefix);

  static bool isKeyAdvert(String text) => text.startsWith(keyPrefix);

  static bool isEncryptedMessage(String text) => text.startsWith(messagePrefix);

  static bool isEncryptedMessagePart(String text) =>
      text.startsWith(messagePartPrefix);

  static AcgoE2eeIdentity generateIdentity() {
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          _secureRandom(),
        ),
      );
    final pair = generator.generateKeyPair();
    return AcgoE2eeIdentity(
      publicKey: pair.publicKey,
      privateKey: pair.privateKey,
    );
  }

  static String encodeIdentity(AcgoE2eeIdentity identity) {
    final key = identity.privateKey;
    return jsonEncode({
      'n': _encodeBigInt(key.modulus!),
      'e': _encodeBigInt(key.publicExponent!),
      'd': _encodeBigInt(key.privateExponent!),
      'p': _encodeBigInt(key.p!),
      'q': _encodeBigInt(key.q!),
    });
  }

  static AcgoE2eeIdentity? tryDecodeIdentity(String encoded) {
    try {
      final json = jsonDecode(encoded);
      if (json is! Map) return null;
      final publicKey = RSAPublicKey(
        _decodeBigInt('${json['n']}'),
        _decodeBigInt('${json['e']}'),
      );
      final privateKey = RSAPrivateKey(
        _decodeBigInt('${json['n']}'),
        _decodeBigInt('${json['d']}'),
        _decodeBigInt('${json['p']}'),
        _decodeBigInt('${json['q']}'),
      );
      return AcgoE2eeIdentity(publicKey: publicKey, privateKey: privateKey);
    } catch (_) {
      return null;
    }
  }

  static String keyAdvertText(RSAPublicKey publicKey) {
    return '$keyPrefix${jsonEncode(_publicKeyToJson(publicKey))}';
  }

  static RSAPublicKey? tryReadKeyAdvert(String text) {
    if (!isKeyAdvert(text)) return null;
    try {
      final json = jsonDecode(text.substring(keyPrefix.length));
      if (json is! Map) return null;
      return publicKeyFromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  static String encodePublicKey(RSAPublicKey publicKey) =>
      jsonEncode(_publicKeyToJson(publicKey));

  static RSAPublicKey? tryDecodePublicKey(String encoded) {
    try {
      final json = jsonDecode(encoded);
      if (json is! Map) return null;
      return publicKeyFromJson(Map<String, dynamic>.from(json));
    } catch (_) {
      return null;
    }
  }

  static RSAPublicKey publicKeyFromJson(Map<String, dynamic> json) {
    return RSAPublicKey(
      _decodeBigInt('${json['n']}'),
      _decodeBigInt('${json['e']}'),
    );
  }

  static String encryptText(
    String text,
    RSAPublicKey peerPublicKey, {
    RSAPublicKey? selfPublicKey,
  }) {
    final material = _randomBytes(64);
    final aesKey = material.sublist(0, 32);
    final macKey = material.sublist(32, 64);
    final iv = _randomBytes(16);
    final cipherText = _aesCbc(
      true,
      aesKey,
      iv,
      Uint8List.fromList(utf8.encode(text)),
    );
    final mac = _hmac(macKey, Uint8List.fromList([...iv, ...cipherText]));
    final wrappedKey = _rsa(true, peerPublicKey, material);
    final selfWrappedKey = selfPublicKey == null
        ? null
        : _rsa(true, selfPublicKey, material);
    return '$messagePrefix${jsonEncode({'k': _b64(wrappedKey), if (selfWrappedKey != null) 'sk': _b64(selfWrappedKey), 'iv': _b64(iv), 'c': _b64(cipherText), 'm': _b64(mac)})}';
  }

  static List<String> encryptTextParts(
    String text,
    RSAPublicKey peerPublicKey, {
    RSAPublicKey? selfPublicKey,
    int maxPartLength = acgoEncryptedPartMaxLength,
  }) {
    final encrypted = encryptText(
      text,
      peerPublicKey,
      selfPublicKey: selfPublicKey,
    );
    if (encrypted.length <= maxPartLength) return [encrypted];
    final partId = _b64(_randomBytes(12));
    return _splitEncryptedText(encrypted, partId, maxPartLength);
  }

  static AcgoE2eeMessagePart? tryReadMessagePart(String text) {
    if (!isEncryptedMessagePart(text)) return null;
    final body = text.substring(messagePartPrefix.length);
    final idEnd = body.indexOf(':');
    if (idEnd <= 0) return null;
    final indexEnd = body.indexOf(':', idEnd + 1);
    if (indexEnd <= idEnd + 1) return null;
    final totalEnd = body.indexOf(':', indexEnd + 1);
    if (totalEnd <= indexEnd + 1) return null;
    final id = body.substring(0, idEnd);
    final index = int.tryParse(body.substring(idEnd + 1, indexEnd));
    final total = int.tryParse(body.substring(indexEnd + 1, totalEnd));
    final data = body.substring(totalEnd + 1);
    if (id.isEmpty ||
        index == null ||
        total == null ||
        index < 1 ||
        total < 1 ||
        index > total ||
        data.isEmpty) {
      return null;
    }
    return AcgoE2eeMessagePart(
      id: id,
      index: index,
      total: total,
      data: data,
    );
  }

  static String? tryDecryptText(String text, RSAPrivateKey privateKey) {
    if (!isEncryptedMessage(text)) return null;
    try {
      final json = jsonDecode(text.substring(messagePrefix.length));
      if (json is! Map) return null;
      final wrappedKey = _unb64('${json['k']}');
      final selfWrappedKey = json['sk'] == null
          ? null
          : _unb64('${json['sk']}');
      final iv = _unb64('${json['iv']}');
      final cipherText = _unb64('${json['c']}');
      final expectedMac = _unb64('${json['m']}');
      var material = _tryRsaDecrypt(privateKey, wrappedKey);
      if (material == null && selfWrappedKey != null) {
        material = _tryRsaDecrypt(privateKey, selfWrappedKey);
      }
      if (material == null) return null;
      if (material.length < 64) return null;
      final aesKey = material.sublist(0, 32);
      final macKey = material.sublist(32, 64);
      final actualMac = _hmac(
        macKey,
        Uint8List.fromList([...iv, ...cipherText]),
      );
      if (!_constantTimeEquals(actualMac, expectedMac)) return null;
      final clearBytes = _aesCbc(false, aesKey, iv, cipherText);
      return utf8.decode(clearBytes);
    } catch (_) {
      return null;
    }
  }

  static List<String> _splitEncryptedText(
    String encrypted,
    String partId,
    int maxPartLength,
  ) {
    var expectedTotal = 1;
    for (var attempt = 0; attempt < 20; attempt++) {
      final parts = <String>[];
      var offset = 0;
      var index = 1;
      while (offset < encrypted.length) {
        final header = '$messagePartPrefix$partId:$index:$expectedTotal:';
        final capacity = maxPartLength - header.length;
        if (capacity <= 0) {
          throw ArgumentError.value(
            maxPartLength,
            'maxPartLength',
            '分段长度过短，无法容纳 FastChat 加密分片头。',
          );
        }
        final end = min(offset + capacity, encrypted.length);
        parts.add('$header${encrypted.substring(offset, end)}');
        offset = end;
        index++;
      }
      if (parts.length == expectedTotal) return parts;
      expectedTotal = parts.length;
    }
    throw StateError('无法稳定计算 FastChat 加密消息分片。');
  }

  static Map<String, String> _publicKeyToJson(RSAPublicKey publicKey) => {
    'n': _encodeBigInt(publicKey.modulus!),
    'e': _encodeBigInt(publicKey.exponent!),
  };

  static Uint8List _aesCbc(
    bool forEncryption,
    Uint8List key,
    Uint8List iv,
    Uint8List input,
  ) {
    final cipher = PaddedBlockCipherImpl(
      PKCS7Padding(),
      CBCBlockCipher(AESEngine()),
    );
    cipher.init(
      forEncryption,
      PaddedBlockCipherParameters(
        ParametersWithIV(KeyParameter(key), iv),
        null,
      ),
    );
    return cipher.process(input);
  }

  static Uint8List _hmac(Uint8List key, Uint8List input) {
    final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(key));
    return mac.process(input);
  }

  static Uint8List _rsa(
    bool forEncryption,
    RSAAsymmetricKey key,
    Uint8List input,
  ) {
    final cipher = PKCS1Encoding(RSAEngine());
    cipher.init(
      forEncryption,
      forEncryption
          ? PublicKeyParameter<RSAPublicKey>(key as RSAPublicKey)
          : PrivateKeyParameter<RSAPrivateKey>(key as RSAPrivateKey),
    );
    return cipher.process(input);
  }

  static Uint8List? _tryRsaDecrypt(RSAPrivateKey privateKey, Uint8List input) {
    try {
      return _rsa(false, privateKey, input);
    } catch (_) {
      return null;
    }
  }

  static SecureRandom _secureRandom() {
    final random = FortunaRandom();
    random.seed(KeyParameter(_randomBytes(32)));
    return random;
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _encodeBigInt(BigInt value) => _b64(_bigIntToBytes(value));

  static BigInt _decodeBigInt(String value) => _bytesToBigInt(_unb64(value));

  static String _b64(Uint8List bytes) => base64UrlEncode(bytes);

  static Uint8List _unb64(String text) =>
      base64Url.decode(base64Url.normalize(text));

  static Uint8List _bigIntToBytes(BigInt value) {
    var hex = value.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) | BigInt.from(byte);
    }
    return result;
  }

  static bool _constantTimeEquals(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

class AcgoE2eeMessagePart {
  const AcgoE2eeMessagePart({
    required this.id,
    required this.index,
    required this.total,
    required this.data,
  });

  final String id;
  final int index;
  final int total;
  final String data;
}
