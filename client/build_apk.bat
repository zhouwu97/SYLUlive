@echo off
flutter build apk --release --target-platform android-arm64 --dart-define=APP_API_URL=http://156.233.229.232:8080/api --dart-define=JPUSH_APP_KEY=fbbd87f741e919f39519afe6
echo.
echo APK: build\app\outputs\flutter-apk\app-release.apk
pause
