# macOS 13 and later

**Status: not yet tested.** Read [PORTING.md](PORTING.md) first, and treat this as a plan.

## Set up

1. Install Python 3.12 with `brew install python@3.12` or from python.org.
2. Create the app folder from PORTING.md in `~/Library/Application Support/Sharingan`.
3. Create a venv, then install the packages, plus `pyobjc-framework-Cocoa`, `pyobjc-framework-Quartz` and `pynput`.
4. Run `tools/ocr.py` once with a test request, to confirm the engine loads.

## Permissions

These are the most likely reasons for failure, and the person has to grant them by hand.

- **Screen Recording** in System Settings, under Privacy & Security. Without it, captures show only the wallpaper and your own windows, with no error. Call `CGRequestScreenCaptureAccess()` and check `CGPreflightScreenCaptureAccess()`. The app must restart after it is granted.
- **Input Monitoring or Accessibility** for `pynput` hotkeys.

Permissions attach to the program that runs, which is the Python binary or the terminal. Tell the person exactly which name to look for. A small app bundle made with `py2app` gives a stable name, which helps if the grant keeps being lost.

## macOS specifics

- **Hotkey.** Command+Option+C already means Copy Style in many apps. Ask the person which key they want. Control+Option+C is a sensible default.
- **Retina.** Frames are at 2× on Retina screens. Check the frame width against the window width and send that ratio as `scale`. `mss` may return logical or native size depending on the call, so measure the result. Native is required.
- **Full-screen apps and Spaces.** A plain Qt window will not appear over a full-screen app. From the `NSWindow` behind `winId()`, set `collectionBehavior` to `canJoinAllSpaces | fullScreenAuxiliary` and `level` to `NSScreenSaverWindowLevel`.
- **Menu bar and Dock.** Set `NSApp.setActivationPolicy_(NSApplicationActivationPolicyAccessory)`, so no Dock icon appears. The windows must cover the menu bar, so set frames from `NSScreen.frame` rather than `visibleFrame`.
- **Focus.** Call `NSApp.activateIgnoringOtherApps_(True)` before `requestActivate()`, or keys will go to the previous app.
- **Shortcuts.** Use Command in place of Ctrl for select all and copy, and change the panel hint to match. Leave Enter and Esc as they are.
- **Graphics.** Qt uses Metal here, and the shaders include MSL.

## Start at login

Add a LaunchAgent in `~/Library/LaunchAgents` that runs the venv's Python on `main.py`, or add the app bundle under Login Items.

## Tesseract fallback

Optional: `brew install tesseract imagemagick`.
