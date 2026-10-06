# SOV Node — iOS

This is the iOS client for the SOV Network, kept here **ready in waiting**.

SOV does not publish it to the App Store. The project has no Apple Developer account, and a
sovereign biometric wallet may not fit Apple's policies today. So the source lives here
instead: **anyone with an Apple Developer account may build this and submit it.** SOV
supplies the code; whoever is able supplies the account and the submission. That is the same
shape as the rest of the network's distribution — SOV makes the artifact, the ecosystem
delivers it.

## What it is

The same client as the Android app: palm enrolment, wallet, transfers, messaging,
governance, the Academy. It is **not** a node — iOS does not permit a background server, so
the phone is a client that connects to nodes other people run, exactly as Android does.

## Building it

```
flutter pub get
flutter build ios --release --no-codesign     # compiles; needs no Apple account
```

`--no-codesign` is what this repository's CI runs on every change, so the source is known to
compile. Producing an installable build is a further step and needs things only a submitter
has: a signing certificate, a team id and a provisioning profile. Set those in Xcode
(`Runner` target → Signing & Capabilities) and then `flutter build ipa`.

## If you are the one submitting it

- The bundle id is `network.sov.node`. Change it to one your team owns if you must; nothing
  in the protocol depends on it.
- The app asks for camera (palm enrolment), Face ID, microphone and photo library. Each has
  a usage string in `Runner/Info.plist` — keep them accurate, Apple reads them.
- The app icon is the network's own. Do not substitute your own branding: people should be
  able to tell they are running SOV.
- Nothing here phones home to any operator. Node discovery is peer-to-peer.

## One pin you must not lower

`google_mlkit_face_detection` is pinned at `^0.12.0`, and the floor is deliberate. Below it,
the plugin asks CocoaPods for `GoogleMLKit/FaceDetection ~> 6.0.0` while `mobile_scanner` asks
for `BarcodeScanning ~> 7.0.0`. Those resolve to different ML Kit cores, CocoaPods allows only
one per app, and `pod install` refuses — the build stops before Xcode ever starts.

Android does not have this problem (Gradle resolves each ML Kit artifact on its own), so a
change that looks harmless on Android can break iOS alone. If you bump `mobile_scanner`, check
that the face-detection plugin still agrees with it on the ML Kit generation.

## Two plugins do not support iOS

`tray_manager` and `window_manager` are desktop-only. They do not break the build — Flutter
simply does not register them on iOS — and every call site is behind a desktop check. CI
asserts that guard still exists, because losing it would fail only on a real device.
