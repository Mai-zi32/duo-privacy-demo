# Duo Privacy Demo source

The native macOS source for an attention-aware privacy overlay. It uses the current main-display contents as an in-memory visual background and applies a Duo-inspired left-to-right frost transition when the active privacy rule is triggered.

## Build

```sh
chmod +x scripts/build_app.sh
scripts/build_app.sh
```

The bundled app is created under `../tmp/build/`.

## Use

1. Launch `Duo Privacy Demo.app`; its control window opens immediately and the app remains available in the Dock.
2. Complete the guided Camera and Screen Recording permission steps. macOS may require the app to be reopened after Screen Recording permission changes.
3. Choose single-person or multi-person mode.
4. Start attention monitoring, or use the built-in permission-free preview to inspect the visual treatment.

Camera frames are processed in memory with Apple Vision and are never stored or uploaded. ScreenCaptureKit captures only the main display, excludes this app, captures no audio, and keeps the desktop frame in bounded memory only.

## One-shot visual QA

```sh
"../tmp/build/Duo Privacy Demo.app/Contents/MacOS/DuoPrivacyDemo" --preview-once
```

This displays the built-in transition once, hides it, and exits.

Use `--preview-hold` instead to keep the privacy view visible until it is clicked.
