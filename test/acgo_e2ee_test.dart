import 'package:fast_chat/acgo/acgo_e2ee.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('acgo encrypted messages split within the 450 character limit', () {
    final sender = AcgoE2ee.generateIdentity();
    final receiver = AcgoE2ee.generateIdentity();
    final text = List.filled(2000, '密').join();

    final parts = AcgoE2ee.encryptTextParts(
      text,
      receiver.publicKey,
      selfPublicKey: sender.publicKey,
    );

    expect(parts, isNotEmpty);
    for (final part in parts) {
      expect(part.length, lessThanOrEqualTo(AcgoE2ee.acgoEncryptedPartMaxLength));
      expect(AcgoE2ee.tryReadMessagePart(part), isNotNull);
    }

    final combined = parts
        .map((part) => AcgoE2ee.tryReadMessagePart(part)!)
        .toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    final mergedText = combined.map((part) => part.data).join();

    expect(AcgoE2ee.tryDecryptText(mergedText, receiver.privateKey), text);
  });
}
