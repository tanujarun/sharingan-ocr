# Behaviour spec

`plugin/Sharingan.qml` is the reference. This is what any port must reproduce. Sizes are in logical pixels, multiplied by the scale `k` (1 by default).

## Flow

1. **Open.** Capture every monitor at native resolution before showing anything. Then show one borderless, always-on-top, full-screen window per monitor, each showing its frozen frame, so the windows themselves are never captured. Start the OCR worker at the same moment, because it needs a few seconds to load and the person is still dragging.
2. **Pick.** Veil every screen with black at 46% opacity and a dot grid (6 px pitch, 1.3 px radius, white at 10%). A hint pill near the top reads `SHARINGAN  DRAG OVER ANY TEXT  ESC`.
3. **Drag.** A clear rounded hole (radius 12) follows the drag, inside a black ring 6 px wide, with a size chip at its corner. Ignore tiny boxes.
4. **Read.** Send the box to the worker. A red band sweeps the dots inside the box and the eye looks side to side.
5. **Ready.** Lit marks appear on the picture, and the panel shows the text.
6. **Close.** Delete frames, stop the worker, and leave nothing behind.

## OCR worker

Start it once per session and speak JSON lines. Run it with the venv's Python.

Request: `{"id", "path", "x", "y", "w", "h", "scale"}`. `x y w h` are native pixels in the frozen frame, and `scale` is native pixels per logical pixel. `path` can be any format OpenCV reads.

Replies: first `{"ready": true, "engine": "RAPIDOCR"}`, then one of:

- `{"id", "engine", "ms", "lines", "text", "codes"}`, where `codes` is the number of QR codes among the lines
- `{"id", "engine", "error"}`

Each line has `text`, `start` (offset in the full text), `cx cy w h angle` (logical px relative to the box), `stops` (the offset along the line of every character boundary), and `conf` (a list of `[first char, end char, 0..1]` per word).

Ignore replies whose `id` is not the latest request. Requests made while the engine loads simply wait.

### Facts that were measured, so do not undo them

- `Global.use_cls` must be `False`. With the classifier on, clean sans text scored 0.73 to 0.88 because lines were flipped 180°. With it off, the mean was 1.000 over 36 size, colour and scale combinations.
- Crop from the native frame, never from a scaled image.
- Each box gets 24 px of replicated edge padding, because the detector misses text touching the edge.
- Lines scoring under 0.5 are dropped.
- Tall boxes are vertical text: both rotations are tried and the better score wins.

### QR codes

`read_codes` in `ocr.py` uses `cv2.QRCodeDetectorAruco`, which beat `cv2.QRCodeDetector` in testing. A code becomes one more line: its text is the payload, its quad is the code's corners, and its confidence is 1.0. It joins the same reading order and selection as any other line. OCR lines centred inside a code are dropped, because they are noise.

Each scale (1×, 2×, 3×, skipping sizes over 16 MP) tries four pictures, and all of them matter:

- The box with replicated padding.
- That picture inverted, for light-on-dark codes.
- The box on a white margin, because a box drawn tight around a code has no quiet zone and otherwise fails.
- The inverted box on a white margin.

All four run at a scale before stopping, because one box can hold both dark and light codes. This read 47 of 48 test codes across sizes, blur, inversion and tilt, at about 14 ms on average. It needs OpenCV, so the Tesseract fallback skips codes when OpenCV is missing. Never open a payload automatically.

## Selection

There is one character range, `selA..selB`, into the full text. The picture and the panel both read and write it.

- On the picture, map the pointer into each line's rotated frame, then use `stops` to find the character.
- Double click selects a word, triple click a line, and Ctrl+A everything.
- Copy takes the selection, or all the text when there is none.

## Copying

- Ctrl+C, the icon and right-click copy and stay open. Right-click takes the line under the pointer unless the click is inside the selection.
- Enter copies and closes after 320 ms.
- Dragging outside the box draws a new one. A plain click outside closes.

## Panel layout

The panel is 620 × 210, capped to the screen width minus 36. It sits below the box, or above it if there is no room, or inside it at the bottom if there is no room either. It is horizontally centred on the box and clamped 18 px from the screen edges.

Panel colours sit on a black bezel, and gaps between tiles are 6 px with an 18 px tile radius:

- **Top tile:** the text in a mono font at 11 px, scrollable, with the copy icon in its bottom-right corner.
- **Bottom left, 164 wide:** word count in light 34 px numerals, `WORDS` or `OF N WORDS`, and the eye.
- **Bottom right:** an `ALL / SELECTED` capsule 164 × 30 with one sliding red pill, then three small lines: confidence, `SHARINGAN  0.7 S` (with `QR` before the time when a code was read), `CTRL C  /  ENTER CLOSES`.

Labels are mono, uppercase, 9.5 px, with 1.6 px letter spacing. The engine line says `TESSERACT` only in the fallback.

The panel joins the ring as one black shape, with a 16 px fillet that must stay outside the box. It grows out of the ring: a short slide to 32%, a small try, a recoil, then a fast ease to full size, about 0.35 s in all. The tiles then pull apart along their seams.

## Confidence

Each word's value is `min(word score, line score)`. The shown value is the mean across the characters Copy would take, weighted by character count, rounded, and capped at 99.

Show ten cells, 4 × 8 with 2 px gaps, lit in proportion and the last one partly lit, then `NN% CONFIDENT`. Under 90, show `NN% UNSURE` in red. Do not recalibrate the score: compared word by word it already matches reality, with a mean error of 0.034 over 5,438 words.

## Colour

| Token | Dark | Light |
|---|---|---|
| Accent | `#DC1F2A` | Same hue, lightness capped at 0.42 |
| Text on accent | `#F6F4EE` | `#F6F4EE` |
| Small red type | `#FF6A6A` | The accent |
| Bezel | `#0A0A0A` | `#111111` |
| Tile | `#1F1F1F` | `#F6F4EE` with 7% accent |
| Inset | `#2A2A2A` | `#E6E1D7` with 12% accent |
| Dots | `#4A4A4A` | `#BEB8AD` with 22% accent |
| Text | `#F2F0EA` | `#111111` |
| Secondary text | `#CFCBC2` | `#333333` |
| Muted | `#8A8A8A` | `#777777` |

Red is fixed and does not follow a system accent. Fonts are Adwaita Sans and JetBrainsMono Nerd Font, or the nearest system sans and mono.

## Animation

Times are real seconds. Everything is driven by one per-frame clock.

**Text reveal.** One timeline runs through the lines in reading order. Each line divides into square blocks as wide as the line is tall. Blocks land one at a time, 20 ms each, for a total of 0.25 to 1 s. Landed blocks are red at 14%. The block being laid is red at 50%, and it fades after the last block lands.

**Copy icon.** Two overlapping rounded squares, 18 px in a 40 px hit area, in secondary text colour.

- Hover: small-red colour in 130 ms, and scale to 1.24 with a strong spring overshoot over 280 ms.
- Press: scale to 0.88.
- Copy: the squares shrink away over 0.26 s while a tick draws itself and pops, held until 1.25 s, then it returns by 1.5 s.

**Copied flood.** A red circle grows from the icon, clipped to the top tile, showing `COPIED` in light 34 px type. It holds, then fades out at about 0.7 s. It must never cover the eye.

**Eye at rest.** A dot grid of 4 px pitch and 3 px dots, 13 columns wide. Half heights per column are `0 1 2 2 3 3 3 3 3 2 2 1 0`, so the shape is a lens. The pupil is 3 × 3 red dots. While reading, the pupil shifts up to 3 columns from side to side.

**Eye at a copy, 1.9 s, always dot-matrix.** Do not draw solid shapes, and keep the red clear of the lids.

| Time | What happens |
|---|---|
| 0 to 0.10 | Lids close to a flat line |
| 0.10 to 0.17 | Stay shut |
| 0.17 to 0.50 | Lids open with overshoot to 1.45× rest height |
| 0.17 to 0.47 | The pupil becomes a ring of 20 red 2 px dots, radius 13, around one 3 px centre dot |
| 0.36 to 1.16 | Three tomoe spin in and slow to a gentle rotation |
| 1.40 to 1.65 | The tomoe spin into the centre and vanish |
| 1.50 to 1.85 | Lids return to rest and the ring tightens |
| 1.90 | Snap back to the rest pupil |

Each tomoe is four dots moving along an orbit of radius 8.5: a 4 px head, then dots of 3, 3 and 2 px at 0.42, 0.8 and 1.15 radians behind it. Moving dots stay crisp, whereas sampling a rotating shape onto a fixed grid turns to noise.

## Light and dark

Light mode is used when the system background is light. On Omarchy and Hyprland the file `~/.local/state/tanuj-card-mode` can force `light`, `dark` or `auto`.
