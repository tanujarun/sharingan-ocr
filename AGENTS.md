# Instructions for AI agents

You were asked to set up Sharingan OCR on this computer. Your job ends when the person presses a shortcut, draws a box and pastes correct text, or when you have said exactly why that did not happen.

## 1. Detect the system, then take one route

Run the checks in order and stop at the first match.

| Check | Route |
|---|---|
| `command -v omarchy` succeeds | Omarchy: run `install/omarchy.sh` |
| `$HYPRLAND_INSTANCE_SIGNATURE` is set | Hyprland: run `install/hyprland.sh`, then add the lines it prints to the person's config |
| Other Linux | Follow [docs/linux-other.md](docs/linux-other.md) |
| Windows | Follow [docs/windows.md](docs/windows.md) with [docs/PORTING.md](docs/PORTING.md) |
| macOS | Follow [docs/macos.md](docs/macos.md) with [docs/PORTING.md](docs/PORTING.md) |

## 2. Know what you have

| Path | What it is | Reuse |
|---|---|---|
| `plugin/tools/ocr.py` | OCR worker, JSON lines on stdin and stdout | Unchanged on every system |
| `plugin/tools/requirements.txt` | Pinned OCR engine | Unchanged, except see the Python note in the guides |
| `plugin/shaders/*.qsb` | Compiled shaders with GLSL, HLSL and MSL | Unchanged in any Qt 6 app |
| `plugin/Sharingan.qml` | The whole interface, on Quickshell | Port it, keeping the behaviour |
| `docs/SPEC.md` | Exact behaviour, timing and colours | The acceptance standard |

## 3. Rules

- Before editing a person's config, read it and back it up. The installers do this.
- Check the shortcut is free first. If it is taken, ask which key they want.
- The installers need network access for about 380 MB of Python packages. Say so before starting on a metered connection.
- Do not change OCR settings. `Global.use_cls` must stay `False`: the angle classifier flips clean lines upside down and turns them into noise. See `docs/SPEC.md`.
- Do not simplify the interface into a plain dialog or a text box of results. Selecting words on the frozen picture is the product.
- Keep OCR local. Do not send screenshots to any service.
- Never leave frozen screen frames on disk after closing. They can hold private information.

## 4. Verify before you say it works

Check every item that applies, and report each one as passed, failed or not checked.

1. The shortcut opens the overlay, and every monitor freezes.
2. A dragged box produces the correct text in the panel on a real document.
3. The clipboard holds exactly the selected text after copying, checked by pasting.
4. The picture selection lands on the right characters, including on a scaled display.
5. Double click, triple click, Ctrl+A, right-click and Enter do what the README says.
6. A box works on a second monitor, and keyboard input follows it.
7. Esc closes, and no OCR process or frozen frame remains.
8. It starts again after a reboot.
9. Dark and light mode both read well.

A check you could not run stays "not checked". On Windows and macOS, the person must grant or confirm some things by hand, so walk them through those steps.

If you could not finish, say which step failed, the exact error, and what the person can do next.
