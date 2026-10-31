# Windows 10 and 11

**Status: not yet tested.** Read [PORTING.md](PORTING.md) first, and treat this as a plan.

## Set up

1. Install Python 3.12 from python.org, for this user, with "Add to PATH" on.
2. Create the app folder from PORTING.md in `%LOCALAPPDATA%\Sharingan`.
3. Create a venv and install the packages with `pip`.
4. Run `python tools\ocr.py` once with a test request, to confirm the engine loads. If `onnxruntime` fails to import, install the latest Visual C++ Redistributable.

## Windows specifics

- **Hotkey.** Use `RegisterHotKey` through `ctypes` with `MOD_WIN | MOD_ALT | MOD_NOREPEAT` and `VK_C`, and read `WM_HOTKEY` with a `QAbstractNativeEventFilter`. If registration fails, the key is taken, so ask the person which one they want. `Ctrl+Alt+C` is a sensible fallback.
- **Focus.** Windows blocks background apps from taking focus. A hotkey press usually grants it, so call `SetForegroundWindow` on the window's handle right after showing it.
- **Scaling.** PySide6 is per-monitor DPI aware by default. Monitors can have different scales and negative coordinates, so use each `QScreen`'s geometry and compute `scale` per monitor.
- **Capture.** `mss` uses GDI here. HDR screens may look washed out, and some protected content comes out black. Exclusive full-screen games may not capture or may not show the overlay; borderless mode is the workaround.
- **Worker pipes.** Spawn the worker with `pythonw.exe` or `CREATE_NO_WINDOW`, so that no console window flashes. Replies are ASCII JSON, so the code page is not a concern.
- **Clipboard.** Other apps can hold the clipboard open briefly. Retry once if setting it fails.
- **Taskbar.** `Qt.Tool` keeps windows off the taskbar and Alt+Tab.

## Start at login

Put a shortcut to `pythonw.exe main.py` in `shell:startup`.

## Tesseract fallback

The fallback needs `tesseract` and `magick` on PATH. They are optional, so skip them unless the person wants them. If RapidOCR fails to load without them, the app must show a clear error.
