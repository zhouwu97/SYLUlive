@echo off
flutter build apk --release --target-platform android-arm64 ^
  --dart-define=APP_API_URL=https://sylulive.online/api ^
  --dart-define=JPUSH_APP_KEY=fbbd87f741e919f39519afe6
echo.
echo APK: build\app\outputs\flutter-apk\app-release.apk
pause
