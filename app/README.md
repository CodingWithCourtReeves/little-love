# littlelove

LittleLove — private messenger for couples

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## iOS

Run on the iPhone simulator (no signing needed):

```sh
./scripts/ios-run.sh                  # boots "iPhone 17" and launches
# or, just to verify the build compiles:
flutter build ios --simulator --no-codesign
```

Build a signed release for a physical iPhone (USB or paired wirelessly):

```sh
cd app && flutter build ios --release
# then open ios/Runner.xcworkspace in Xcode, select your iPhone, click Run.
```

Bundle ID (`dev.littlelove.littlelove`) and dev team (`33HDFY8B9F`) are
pinned in `app/ios/Flutter/AppInfo.xcconfig`. Court holds the Apple
Developer account. TestFlight upload is a later task.
