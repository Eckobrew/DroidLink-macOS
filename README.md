# Droid Link for macOS

A native macOS companion and desktop hub for your Android phone. Seamlessly sync messages, incoming notifications, calls, contacts, media playback, and run phone screen mirroring directly on macOS Sequoia+.

<p align="center">
  <img src="Resources/AppIcon.icns" width="160" alt="Droid Link App Icon" />
</p>

## Features

- **End-to-End Encrypted Sync**: High-speed local Wi-Fi pairing via QR code with automatic fallback to encrypted Bluetooth LE.
- **Messages & SMS**: Full message history, direct SMS composition with delivery callbacks, and MMS/RCS photo viewing. Notification replies show **Sent to messaging app**; SMS/RCS badges appear only when the transport is known. A handoff to the messaging app does not confirm carrier delivery.
- **Phone Calls & Handset Audio**: In-call controls (dial, answer, reject, DTMF keypad) with Bluetooth HFP audio routing to your Mac's speakers and microphone.
- **Persistent Menu Bar**: Quick access to live connection status, messages, calls, and settings even with the main window closed.
- **Interactive Notifications**: Live notification sidebar with native macOS notification banner toasts and inline replies.
- **Media Controls & Audio Handoff**: Auto-appearing media playback controls with album artwork.
- **Phone Screen Mirroring**: Integrated low-latency `scrcpy` and `adb` client for screen interaction and app management.

## Requirements

- macOS 15.0+ (Sequoia or later)
- Xcode 16+ / Swift 6.0+
- Paired with [Droid Link for Android](https://github.com/Eckobrew/DroidLink-Android)

## Building from Source

Build the universal binary (Apple Silicon + Intel) and application bundle:

```bash
# Run unit tests
swift test

# Build Universal Droid Link.app
./build_universal.sh
```

The resulting application is placed at `build/Droid Link.app`.

## License

See [LICENSE](Resources/scrcpy/LICENSE) for included subcomponents.
