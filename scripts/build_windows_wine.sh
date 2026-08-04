#!/usr/bin/env bash
set -euo pipefail

FLUTTER_WIN="${FLUTTER_WIN:-/home/archzero/下载/flutter_windows_3.44.8-stable/flutter}"
DART_EXE="Z:${FLUTTER_WIN//\//\\}\\bin\\cache\\dart-sdk\\bin\\dart.exe"
FLUTTER_TOOLS="Z:${FLUTTER_WIN//\//\\}\\bin\\cache\\flutter_tools.snapshot"
MINGIT="Z:${FLUTTER_WIN//\//\\}\\bin\\mingit\\cmd"

export WINEPATH="${MINGIT}${WINEPATH:+;$WINEPATH}"

wine "$DART_EXE" "$FLUTTER_TOOLS" pub get
wine "$DART_EXE" "$FLUTTER_TOOLS" build windows --release
