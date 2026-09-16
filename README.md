# Duo Privacy Demo

Duo Privacy Demo is an experimental native macOS privacy overlay. It watches attention locally and turns the current main display into a continuous frosted-glass surface when the active privacy rule is triggered.

## What it does

- **Single-person mode:** covers the display after the user turns away or leaves the camera frame.
- **Multi-person mode:** registers a session-only controller, stays idle while only one person is present, and arms after a second face appears. Once armed, only the controller's attention can keep the display visible.
- **Duo-style transition:** preserves the desktop's composition and colors while progressively obscuring text and fine detail from left to right.
- **Guided permissions:** explains and requests Camera and Screen Recording permission before the main controls become available.

## Privacy boundary

- Camera and desktop frames are processed locally in bounded memory.
- Frames are not recorded, persisted, or uploaded.
- The app captures no audio and has no network feature.
- Controller references, landmarks, and gaze baselines exist only for the current monitoring session.
- This is a convenience privacy overlay, not biometric authentication or a replacement for macOS Lock Screen.

## Requirements

- macOS 13 or newer
- A built-in or connected camera
- Camera and Screen Recording permission

## Build

```sh
cd code
./scripts/build_app.sh
```

The development app bundle is created at `tmp/build/Duo Privacy Demo.app` relative to the repository root.

Run the local logic checks with:

```sh
cd code
swift build -c release
./.build/release/DuoPrivacyDemo --logic-self-test
```

## Current limitations

- Main display only
- Webcam gaze is approximate and affected by glasses, lighting, camera position, and occlusion
- Controller matching is session-only and is not security-grade face recognition
- Development builds are ad-hoc signed and may require permissions again after replacement

## Visual reference

[MacDuo](https://github.com/DhananjayBhosale/MacDuo) served as a visual motion reference. Duo Privacy Demo uses its own attention, permission, privacy-state, capture, and overlay implementation.

## License

Released under the [MIT License](LICENSE).
