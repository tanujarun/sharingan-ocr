# Other Linux desktops

**Status: not yet tested.** Only Omarchy and Hyprland have been run. The plugin needs three things from the desktop: Wayland layer-shell windows, a way to capture each output, and a focused-monitor query. Pick the route that matches.

| Desktop | Route | Change |
|---|---|---|
| Sway, river, other wlroots | Quickshell | `install/hyprland.sh` needs `hyprctl` removed from its `need` line. Replace the focused monitor |
| KDE Plasma on Wayland | Quickshell | Replace capture and the focused monitor |
| GNOME on Wayland | PySide6 | GNOME has no layer shell, so follow [PORTING.md](PORTING.md) |
| Any X11 session | PySide6 | Follow [PORTING.md](PORTING.md). `mss` captures X11 directly |

## Quickshell route

Install Quickshell, then use the `install/hyprland.sh` steps. Without Hyprland, `Hyprland.focusedMonitor` is empty and the overlay falls back to the first screen, so change `open()` in `Sharingan.qml`:

- **Sway:** run `swaymsg -t get_outputs` and take the entry where `focused` is true.
- **KDE:** take the screen under the pointer.

The first press in any window sets `activeName`, so a box drawn on another screen still works, but the hint appears only on the active one.

**Capture.** `tools/capture.sh` uses `grim`, which needs `wlr-screencopy`. It works on wlroots compositors. On KDE, use `spectacle --background --nonotify --fullscreen --output <file>` and crop each monitor from the result, or capture each with `spectacle --current`. The rest of the code expects one file per monitor, named `<output>-<stamp>.ppm`, and any image format works if you update `framePath`.

**Shortcut and autostart.** Bind `quickshell ipc -c sharingan call sharingan toggle` to a key, and start `quickshell -c sharingan` at login. Disable compositor animations on the `tanuj-sharingan` layer namespace if your compositor supports that.

## GNOME notes

Capture goes through the `org.freedesktop.portal.Screenshot` portal or `gnome-screenshot`. The portal may show a confirmation dialog, and capturing takes longer. Global hotkeys cannot be registered by an app, so add a custom shortcut in Settings that runs a command telling the background process to open, such as a small socket client. Use `showFullScreen()` on each window, since positioning is limited on Wayland.

## Packages

`grim`, `wl-clipboard`, Python 3 with `venv`, and a Quickshell build for your distribution. `libnotify` gives error notifications. `tesseract` and `imagemagick` are optional.
