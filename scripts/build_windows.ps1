$ErrorActionPreference = "Stop"

flutter pub get
flutter analyze
flutter test
flutter build windows --release

$output = "fast-chat-windows.zip"
if (Test-Path $output) {
  Remove-Item $output
}

Compress-Archive -Path "build/windows/x64/runner/Release/*" -DestinationPath $output
Write-Host "Windows package written to $output"
