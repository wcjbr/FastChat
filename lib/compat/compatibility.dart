import 'dart:io';

class Compatibility {
  Compatibility._();

  static bool peSafe = false;

  static void initialize(List<String> args) {
    peSafe =
        Platform.isWindows &&
        (args.contains('--pe-safe') ||
            Platform.environment['FAST_CHAT_PE_SAFE'] == '1');
  }

  static bool get canUseSystemNotifications => !peSafe && !Platform.isWindows;

  static bool get canOpenSavedFiles => !peSafe;
}
