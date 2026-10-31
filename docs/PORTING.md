# Porting to Windows, macOS and other desktops

**Status: not yet tested.** Nothing in this guide has been run on Windows or macOS. It is a plan grounded in how the Linux version works. Where reality differs, trust what you observe, keep to `SPEC.md`, and tell the person what you changed.

## Recommended stack

Use **Python, PySide6 and QtQuick**. Qt Quick is what the interface already runs on, so most of `Sharingan.qml` moves over directly, and the compiled shaders already contain HLSL for Direct3D and MSL for Metal. Writing a new interface in another toolkit means rebuilding all of `SPEC.md` by hand, so avoid it unless Qt cannot be installed.

```text
sharingan/
  main.py          hotkey, capture, windows, worker, clipboard, tray
  ui/Sharingan.qml adapted from plugin/Sharingan.qml
  ui/shaders/      copied from plugin/shaders
  tools/ocr.py     copied unchanged
```

Install everything in one venv, so `ocr.py` can run through `sys.executable` in a `QProcess`.

```text
pip install -r plugin/tools/requirements.txt PySide6 mss
```

Those requirements are pinned for Python 3.14 on Linux. If a wheel is unavailable, use Python 3.12 or 3.13 and unpin to `rapidocr onnxruntime`.

## What to replace in Sharingan.qml

| In the QML today | Replace with |
|---|---|
| `import Quickshell`, `.Io`, `.Wayland`, `.Hyprland` | Remove. Use `QtQuick` and `QtQuick.Window` |
| `import qs.Commons`, `Style`, `Color` | A context property or small singleton giving `k = 1` and the system background |
| `Variants` + `PanelWindow` | `Instantiator` over `Qt.application.screens` creating `Window` |
| `WlrLayershell.*`, `exclusionMode` | `flags: Qt.FramelessWindowHint \| Qt.WindowStaysOnTopHint \| Qt.Tool`, and geometry set to the screen's |
| `Hyprland.focusedMonitor` | The screen holding the pointer, from `QCursor.pos()` |
| `capture.sh` via `Process` | `mss` from Python, one PNG per monitor |
| `worker.sh` via `Process` | `QProcess` on `ocr.py`, or a Python subprocess with a reader thread |
| `FileView` for card mode | `Qt.styleHints.colorScheme` |
| `wl-copy` | `QGuiApplication.clipboard().setText(text)` |
| `rm` of frames | `os.unlink` for each file, and `tempfile.mkdtemp` for the folder |
| `omarchy-notification-send` | Tray icon message |
| `Quickshell.env`, `toolPath` | Paths passed in from Python |
| `framePath` with `file://` | `QUrl.fromLocalFile(path)`, which also handles `C:\` paths |
| `Quiet.js`, `shell.hide` | Remove |
| `root.frameWindow`, `onAfterAnimating` | Keep the pattern, or use `FrameAnimation` to drive `tick()` |

Keep the state, geometry, selection, palette and all component code. These do not depend on Quickshell.

## Capture

Capture **before** showing windows. Use `mss` with one monitor at a time and save PNGs. Compute `frameScale = frame width / window width` per monitor and send that as `scale`, because a wrong value here makes selections land on the wrong characters. Remember to create the Image in a mapped window, because a hidden QML `Window` may not load it.

Create the temp folder readable only by the user, as frames can hold passwords and private messages.

## Running in the background

Keep one Python process running with a tray icon, the hotkey listener and the Qt app, and show the windows on demand. Start the OCR worker at open and stop it at close so it takes no memory the rest of the time.

## Keyboard focus

The overlay needs keyboard focus for Esc, Ctrl+C, Ctrl+A and Enter. Call `requestActivate()` on the active window. Test this first, since it is the most likely thing to fail on each system.

## Packaging

Run from a venv first and get every check in `AGENTS.md` passing. Package only if the person asks for it, with PyInstaller or `pyside6-deploy`, and include `ui/`, `tools/` and the model files RapidOCR downloads.
