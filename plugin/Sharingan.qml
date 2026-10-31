import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import QtQuick
import qs.Commons
import "Quiet.js" as Quiet

// Sharingan, a snipping tool for text. The screen freezes, a box is dragged over anything, and the words in it become
// selectable where they sit in the picture. The box's black ring is the card: a dock grows out of it, fused,
// and splits along its seams. The picture and the dock's text share one character range (selA..selB), so a
// drag in either place drives both. Copying keeps it open, Enter copies and closes, Esc closes.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ---- state -------------------------------------------------------------
  property bool opened: false               // what the shell asks about; false from the moment closing starts
  property bool shown: false                // the windows are mapped
  property string stage: "idle"             // idle, pick, drag, reading, ready, empty, failed
  property string activeName: ""
  property string stamp: ""
  property string frameStamp: ""            // set once grim has finished, so the images never race it
  property int framesLoaded: 0
  property string engineName: ""
  property int readMs: 0
  property int requestId: 0

  property real boxX: 0
  property real boxY: 0
  property real boxW: 0
  property real boxH: 0
  property real pressX: 0
  property real pressY: 0
  property bool pressOutside: false
  property bool selecting: false
  property int anchorChar: 0
  property int clicks: 0
  property real lastClickAt: 0
  property bool overText: false

  property var lines: []
  property string fullText: ""
  property int selA: 0
  property int selB: 0
  readonly property bool hasSel: selB > selA
  readonly property string copyText: hasSel ? fullText.slice(selA, selB) : fullText
  readonly property int wordCount: wordsIn(copyText)
  readonly property int totalWords: wordsIn(fullText)
  // how sure the reader is of the text Copy would take: never 100, the engine can be sure and still wrong
  readonly property int confPct: {
    var c = hasSel ? confidenceOf(selA, selB) : -1
    if (c < 0) c = confidenceOf(0, fullText.length)
    return Math.max(0, Math.min(99, Math.round(c * 100)))
  }
  readonly property bool confLow: confPct < 90
  property real confShown: readable ? confPct : 0
  Behavior on confShown { NumberAnimation { duration: 420; easing.type: Easing.OutQuint } }
  readonly property bool hasBox: stage !== "idle" && stage !== "pick"
  readonly property bool hasDock: stage === "reading" || stage === "ready" || stage === "empty" || stage === "failed"
  readonly property bool readable: stage === "ready"

  // ---- the frame clock (comp ms, run faster than the cards': this is a tool opened many times a day) ----
  readonly property real compRate: 1.6
  property real lastTick: 0
  property real veil: 0                     // 0..1 the frozen screen's veil
  property real closeT: 0                   // 0..1 the exit
  property bool closing: false
  property real dockClock: 0
  property real igniteClock: 0
  property real scanClock: 0
  property real scanAmt: 0
  property real floodT: -1                  // comp ms since the last copy; -1 = at rest
  property real kick: 0                     // 1 at a copy, decays: the numeral reads it
  property real eyeT: -1                    // seconds since the last copy, -1 = at rest: the eye and the copy icon
  readonly property real eyeEnd: 1.9
  readonly property real dockEnd: 1520
  readonly property bool animating: shown && (closing || veil < 1 || dockClock < dockEnd && hasDock
    || igniteClock < igniteEnd && readable || stage === "reading" || scanAmt > 0.002 || floodT >= 0 || kick > 0.01 || eyeT >= 0)

  function clamp01(v) { return Math.max(0, Math.min(1, v)) }
  function quint(t) { var u = 1 - clamp01(t); return 1 - u * u * u * u * u }
  // the lit marks arrive block by block, one timeline through the lines in reading order
  function blocksIn(line) { return Math.max(1, Math.ceil(line.w / Math.max(line.h, 8 * k))) }
  readonly property var blockStarts: {
    var at = 0, starts = []
    for (var i = 0; i < lines.length; i++) { starts.push(at); at += blocksIn(lines[i]) }
    starts.push(at)
    return starts
  }
  readonly property int blockTotal: blockStarts[blockStarts.length - 1]
  readonly property real blockMs: blockTotal > 0 ? Math.max(420, Math.min(1600, blockTotal * 32)) / blockTotal : 32
  readonly property real igniteEnd: blockMs * (blockTotal + 2)
  function wordsIn(s) { var m = String(s).match(/\S+/g); return m ? m.length : 0 }
  function confidenceOf(a, b) {                 // the words' scores, weighted by the characters in a..b
    var sum = 0, weight = 0
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i]
      for (var j = 0; j < l.conf.length; j++) {
        var n = Math.min(b, l.start + l.conf[j][1]) - Math.max(a, l.start + l.conf[j][0])
        if (n > 0) { sum += n * l.conf[j][2]; weight += n }
      }
    }
    return weight > 0 ? sum / weight : -1
  }

  function tick() {
    var t = Date.now()
    var dt = Math.min(0.05, (t - lastTick) / 1000)
    lastTick = t
    if (dt <= 0) return
    var comp = dt * 1000 * compRate
    veil = Math.min(1, veil + dt / 0.14)
    if (hasDock) dockClock = Math.min(dockEnd, dockClock + comp)
    if (readable) igniteClock = Math.min(igniteEnd, igniteClock + comp)
    if (stage === "reading") {
      scanClock += dt
      scanAmt = Math.min(1, scanAmt + dt * 6)
    } else if (scanAmt > 0) {
      scanAmt = Math.max(0, scanAmt - dt * 5)
    }
    if (floodT >= 0) {
      floodT += comp
      if (floodT > 1100) floodT = -1
    }
    kick *= Math.exp(-3.2 * dt)
    if (eyeT >= 0) {
      eyeT += dt
      if (eyeT > eyeEnd) eyeT = -1
    }
    if (closing) {
      closeT = Math.min(1, closeT + dt / 0.2)
      if (closeT >= 1) finishClose()
    }
  }

  // ---- the dock's unroll and seams (the family's curves, verbatim, on this card's timing) ----
  readonly property real k: Style.effectiveSpacingScale
  readonly property real pad: 6 * k
  readonly property real dockW: Math.min(620 * k, screenW - 36 * k)
  readonly property real dockH: 210 * k
  readonly property real stripH: 62 * k
  readonly property real countW: 164 * k
  readonly property var pulls: ({ block: 640, x0: 790 })
  readonly property real pullDur: 240
  readonly property real gapMax: 18 * k

  function tearOf(name) {
    var p = clamp01((dockClock - pulls[name] + pullDur) / pullDur)
    return p * p
  }
  function gapOf(name) {
    var t = dockClock - pulls[name]
    if (t < -pullDur) return 0
    if (t < 0) { var p = (t + pullDur) / pullDur; return gapMax * p * p * p }
    return pad + (gapMax - pad) * Math.exp(-t / 130) * Math.cos(Math.PI * Math.min(t, 660) / 220)
  }
  // slide out, try, recoil, then the fast quint race to full size
  function revealOf(c) {
    if (c < 150) return 0.32 * quint(c / 150)
    if (c < 240) return 0.32 + 0.05 * Math.sin((c - 150) / 90 * Math.PI)
    if (c < 300) return 0.32 - 0.05 * Math.sin((c - 240) / 60 * Math.PI / 2)
    return 0.27 + 0.73 * quint((c - 300) / 260)
  }
  readonly property real dockShown: {
    var h = dockH * revealOf(dockClock)
    if (closing) h *= 1 - quint(closeT)
    return h
  }
  readonly property real iconIn: quint((dockClock - 880) / 240)
  readonly property real floodR: floodT < 0 ? 0 : quint(floodT / 420) * (dockW + dockH)
  readonly property real floodA: floodT < 0 ? 0 : 1 - clamp01((floodT - 720) / 380)

  // ---- geometry of the box and the dock on the active screen -----------------------
  property real screenW: 1920
  property real screenH: 1080
  readonly property real ring: pad
  readonly property string dockSide: {
    if (boxY + boxH + ring + dockH + 10 * k <= screenH) return "below"
    if (boxY - ring - dockH - 10 * k >= 0) return "above"
    return "inside"
  }
  readonly property real dockX: Math.max(18 * k, Math.min(screenW - dockW - 18 * k, boxX + boxW / 2 - dockW / 2))
  readonly property real dockY: dockSide === "below" ? boxY + boxH + ring - 2
    : dockSide === "above" ? boxY - ring - dockH + 2 : boxY + boxH - dockH - 14 * k
  // the dock grows away from the ring; "inside" has no ring to grow from, so it rises from its foot
  readonly property real dockTop: dockSide === "below" ? dockY : dockY + dockH - dockShown

  // ---- palette (the media card's, blended by one animated lightT) ------------------
  function toColor(c) { return typeof c === "string" ? Qt.color(c) : c }
  function mix(a, b, t) {
    var x = toColor(a), y = toColor(b)
    return Qt.rgba(x.r + (y.r - x.r) * t, x.g + (y.g - x.g) * t, x.b + (y.b - x.b) * t, 1)
  }
  function deepen(c, maxL) {
    var x = toColor(c)
    return Qt.hsla(Math.max(0, x.hslHue), x.hslSaturation, Math.min(x.hslLightness, maxL), 1)
  }
  function luminanceOf(c) { var x = toColor(c); return 0.2126 * x.r + 0.7152 * x.g + 0.0722 * x.b }
  function linear(v) { return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4) }
  function inkOn(c) {
    var x = toColor(c), L = 0.2126 * linear(x.r) + 0.7152 * linear(x.g) + 0.0722 * linear(x.b)
    return (L + 0.05) / 0.0556 > 0.968 / (L + 0.05) ? "#111111" : "#F6F4EE"
  }
  property string modePref: "auto"
  readonly property bool lightMode: modePref === "light" ? true
    : modePref === "dark" ? false : luminanceOf(Color.background || "#101315") > 0.5
  FileView {
    path: Quickshell.env("HOME") + "/.local/state/tanuj-card-mode"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: root.modePref = String(text() || "").trim() || "auto"
    onLoadFailed: root.modePref = "auto"
  }
  property real lightT: lightMode ? 1 : 0
  Behavior on lightT { NumberAnimation { duration: 450; easing.type: Easing.InOutCubic } }
  readonly property color brand: "#DC1F2A"      // fixed, not the theme's: the one colour this tool is named for
  readonly property QtObject ui: QtObject {
    readonly property color accent: root.mix(root.brand, root.deepen(root.brand, 0.42), root.lightT)
    readonly property color accentFg: root.inkOn(accent)
    readonly property color accentInk: root.mix("#FF6A6A", accent, root.lightT)   // small type on a panel
    readonly property color bezelAccent: "#FF6A6A"         // small type on the black bezel, in both modes
    readonly property color bezel: root.mix("#0A0A0A", "#111111", root.lightT)
    readonly property color body: root.mix("#1F1F1F", root.mix("#F6F4EE", accent, 0.07), root.lightT)
    readonly property color sub: root.mix("#2A2A2A", root.mix("#E6E1D7", accent, 0.12), root.lightT)
    readonly property color line: root.mix("#4A4A4A", root.mix("#BEB8AD", accent, 0.22), root.lightT)
    readonly property color ink: root.mix("#F2F0EA", "#111111", root.lightT)
    readonly property color ink2: root.mix("#CFCBC2", "#333333", root.lightT)
    readonly property color mute: root.mix("#8A8A8A", "#777777", root.lightT)
    readonly property color bezelInk: "#F2F0EA"            // the bezel is black in both modes
    readonly property string sans: "Adwaita Sans"
    readonly property string mono: "JetBrainsMono Nerd Font"
  }

  // ---- lifecycle -----------------------------------------------------------
  readonly property string runDir: Quickshell.env("XDG_RUNTIME_DIR") + "/tanuj-sharingan"
  function toolPath(name) {
    var url = String(Qt.resolvedUrl("tools/" + name))
    if (url.indexOf("file://") !== 0) return Quickshell.shellPath("plugin/tools/" + name)    // inside the config folder
    return decodeURIComponent(url.replace(/^file:\/\//, ""))
  }
  function framePath(name) { return runDir + "/" + name + "-" + stamp + ".ppm" }

  function open() {
    if (opened) return
    if (closing) finishClose()
    opened = true
    var focused = Hyprland.focusedMonitor ? String(Hyprland.focusedMonitor.name || "") : ""
    var names = [], screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) names.push(screens[i].name)
    activeName = names.indexOf(focused) >= 0 ? focused : names[0]
    stamp = String(Date.now())
    framesLoaded = 0
    capture.command = ["bash", toolPath("capture.sh"), runDir, stamp].concat(names)
    capture.running = true
    worker.running = true                     // loads the models while the user is still dragging
  }

  function close() {
    if (!opened) return
    opened = false
    if (shown) {
      closing = true
      closeT = 0
      lastTick = Date.now()
      kickFrame()
    } else {
      finishClose()
    }
  }

  function dismiss() {
    close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "tanuj.sharingan")
  }

  function finishClose() {
    shown = false
    closing = false
    closeT = 0
    stage = "idle"
    veil = 0
    resetResult()
    stamp = ""
    frameStamp = ""
    worker.running = false
    capture.running = false
    Quiet.release("tanuj.sharingan")
    Quickshell.execDetached(["bash", "-c", 'rm -f "${1:?}"/*.ppm', "bash", root.runDir])   // the frozen screen never outlives the session
  }

  function fail(message) {
    Quickshell.execDetached(["bash", "-c", 'command -v omarchy-notification-send >/dev/null && exec omarchy-notification-send Sharingan "$1"; exec notify-send Sharingan "$1"', "bash", message])
    dismiss()
  }

  function resetResult() {
    lines = []
    fullText = ""
    selA = 0
    selB = 0
    dockClock = 0
    igniteClock = 0
    floodT = -1
    eyeT = -1
    overText = false
  }

  function frameReady() {
    framesLoaded += 1
    if (framesLoaded < Quickshell.screens.length || !opened) return
    frameTimeout.stop()
    Quiet.hold("tanuj.sharingan")
    lastTick = Date.now()
    stage = "pick"
    shown = true
  }

  Component.onDestruction: Quiet.release("tanuj.sharingan")

  Process {
    id: capture
    onExited: function(code) {
      if (!root.opened) return
      if (code !== 0) root.fail("Could not capture the screen")
      else {
        root.frameStamp = root.stamp
        frameTimeout.restart()
      }
    }
  }
  Timer { id: frameTimeout; interval: 2500; onTriggered: root.fail("The frozen screen did not load") }

  Process {
    id: worker
    command: ["bash", root.toolPath("worker.sh")]
    stdinEnabled: true
    stdout: SplitParser { onRead: function(data) { root.handleWorkerLine(data) } }
    onRunningChanged: if (!running && root.stage === "reading") root.stage = "failed"
  }

  function handleWorkerLine(data) {
    var msg
    try { msg = JSON.parse(data) } catch (e) { return }
    if (msg.ready) { engineName = msg.engine; return }
    if (msg.id !== requestId || stage !== "reading") return
    engineName = msg.engine
    if (msg.error) { console.warn("tanuj.sharingan:", msg.error); stage = "failed"; return }
    readMs = msg.ms
    lines = msg.lines
    fullText = msg.text
    selA = 0
    selB = 0
    igniteClock = 0
    stage = msg.lines.length > 0 ? "ready" : "empty"
  }

  function kickFrame() {
    var w = root.frameWindow
    if (w) w.update()
  }
  property var frameWindow: null
  onAnimatingChanged: kickFrame()

  // ---- the box -----------------------------------------------------------------
  function startBox(x, y) {
    resetResult()
    pressX = x
    pressY = y
    boxX = x
    boxY = y
    boxW = 0
    boxH = 0
    stage = "drag"
  }
  function dragBox(x, y, w, h) {
    x = Math.max(0, Math.min(w, x))
    y = Math.max(0, Math.min(h, y))
    boxX = Math.min(x, pressX)
    boxY = Math.min(y, pressY)
    boxW = Math.abs(x - pressX)
    boxH = Math.abs(y - pressY)
  }
  function endBox(frameScale) {
    if (boxW < 12 * k || boxH < 8 * k) {       // a click, not a box
      dismiss()
      return
    }
    requestId += 1
    stage = "reading"
    dockClock = 0
    scanClock = 0
    var req = { id: requestId, path: framePath(activeName), scale: frameScale,
                x: Math.round(boxX * frameScale), y: Math.round(boxY * frameScale),
                w: Math.round(boxW * frameScale), h: Math.round(boxH * frameScale) }
    worker.write(JSON.stringify(req) + "\n")
  }

  // ---- text under the pointer: line-local coordinates, so rotated lines work too ------
  function hitAt(px, py) {                     // box-relative; returns { line, chr, inside } or null
    var best = null, bestD = 1e9
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i], a = l.angle * Math.PI / 180, c = Math.cos(a), s = Math.sin(a)
      var dx = px - l.cx, dy = py - l.cy
      var u = dx * c + dy * s + l.w / 2, v = -dx * s + dy * c
      var du = Math.max(0, -u, u - l.w), dv = Math.max(0, Math.abs(v) - l.h / 2)
      var d = Math.sqrt(du * du + dv * dv)
      if (d < bestD) { bestD = d; best = { line: i, u: u } }
    }
    if (!best) return null
    var st = lines[best.line].stops, chr = 0, near = 1e9
    for (var j = 0; j < st.length; j++) {
      var e = Math.abs(st[j] - best.u)
      if (e < near) { near = e; chr = j }
    }
    return { line: best.line, chr: lines[best.line].start + chr, inside: bestD < 3 * k }
  }

  function setSel(a, b) {
    selA = Math.max(0, Math.min(a, b))
    selB = Math.min(fullText.length, Math.max(a, b))
  }
  function isSpace(c) { return c === undefined || /\s/.test(c) }
  function selectWordAt(at) {
    var a = at, b = at
    if (isSpace(fullText[a]) && a > 0) a -= 1
    b = a
    while (a > 0 && !isSpace(fullText[a - 1])) a -= 1
    while (b < fullText.length && !isSpace(fullText[b])) b += 1
    setSel(a, b)
  }
  function selectLine(i) { setSel(lines[i].start, lines[i].start + lines[i].text.length) }

  function countClick() {
    var t = Date.now()
    clicks = t - lastClickAt < 380 ? clicks + 1 : 1
    lastClickAt = t
  }
  function lineOfChar(at) {
    for (var i = lines.length - 1; i >= 0; i--) if (lines[i].start <= at) return i
    return 0
  }
  function pressText(at) {                     // a press at a character, on the picture or in the dock
    countClick()
    if (clicks === 2) { selectWordAt(at); return }
    if (clicks >= 3) { selectLine(lineOfChar(at)); return }
    selecting = true
    anchorChar = at
    setSel(at, at)
  }
  function pressBox(px, py) {
    var h = hitAt(px, py)
    if (h && h.inside) pressText(h.chr)
    else setSel(0, 0)
  }
  function moveBox(px, py) {
    var h = hitAt(px, py)
    if (selecting && h) setSel(anchorChar, h.chr)
    overText = !!h && h.inside
  }

  // ---- copying --------------------------------------------------------------------
  function copy(andClose) {
    if (!readable) return
    Quickshell.execDetached(["wl-copy", "--", copyText])
    floodT = 0
    kick = 1
    eyeT = 0
    if (andClose) closeAfterCopy.restart()
  }
  function copyLineAt(px, py) {
    var h = hitAt(px, py)
    if (h && h.inside && !(hasSel && h.chr >= selA && h.chr <= selB)) selectLine(h.line)
    copy(false)
  }
  Timer { id: closeAfterCopy; interval: 320; onTriggered: root.dismiss() }

  function handleKey(event) {
    var ctrl = (event.modifiers & Qt.ControlModifier) !== 0
    if (event.key === Qt.Key_Escape) dismiss()
    else if (ctrl && event.key === Qt.Key_C) copy(false)
    else if (ctrl && event.key === Qt.Key_A && readable) setSel(0, fullText.length)
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) copy(true)
    else return
    event.accepted = true
  }

  // ---- small parts --------------------------------------------------------------
  component MonoLabel: Text {
    color: root.ui.mute
    font.family: root.ui.mono
    font.pixelSize: 9.5 * root.k
    font.letterSpacing: 1.6 * root.k
    font.capitalization: Font.AllUppercase
    textFormat: Text.PlainText
  }

  // The reader: a dot-matrix eye. It sweeps along the line while the engine works. At a copy it activates: a blink,
  // the lids open wider than rest, the pupil becomes a ring of dots around one small dot and three tomoe spin in,
  // then they spin out and the eye settles. Each tomoe is a few dots that travel the orbit, which stays crisp where
  // sampling a turning shape onto the grid does not.
  component ReadingEye: Canvas {
    id: eye
    property int look: 0
    property real t: -1
    readonly property real cell: 4 * root.k
    readonly property var lid: [0, 1, 2, 2, 3, 3, 3, 3, 3, 2, 2, 1, 0]   // half height per column, in cells, at rest
    readonly property real wide: 1.45
    readonly property var tomoeDots: [[0, 4], [0.42, 3], [0.8, 3], [1.15, 2]]     // head, then the tail: radians behind it, size
    implicitWidth: 13 * cell
    implicitHeight: 11 * cell                   // room for the wide eye; at rest it uses the middle seven rows
    onLookChanged: requestPaint()
    onTChanged: requestPaint()

    function smooth(v) { var u = root.clamp01(v); return u * u * (3 - 2 * u) }
    function backOut(v) { var u = root.clamp01(v) - 1; return 1 + 2.70158 * u * u * u + 1.70158 * u * u }
    function openAt(t) {
      if (t < 0) return 1
      if (t < 0.1) return 1 - smooth(t / 0.1)
      if (t < 0.17) return 0
      if (t < 1.5) return wide * backOut((t - 0.17) / 0.33)
      return wide + (1 - wide) * smooth((t - 1.5) / 0.35)
    }
    function spot(c, x, y, size) {
      var px = Math.max(1, Math.round(size * root.k))
      c.fillRect(Math.round(x - px / 2), Math.round(y - px / 2), px, px)
    }
    onPaint: {
      var c = getContext("2d"), s = cell, d = Math.max(1, s - 1), open = openAt(t), mid = 5
      c.clearRect(0, 0, width, height)
      c.fillStyle = root.ui.ink2
      var heights = lid.map(function(h) { return Math.round(h * Math.max(0, open)) })
      for (var x = 0; x < 13; x++) {
        var near = Math.max(x > 0 ? heights[x - 1] : 0, x < 12 ? heights[x + 1] : 0)
        for (var r = heights[x]; r <= Math.max(heights[x], near - 1); r++) {
          c.fillRect(x * s, (mid - r) * s, d, d)
          c.fillRect(x * s, (mid + r) * s, d, d)
        }
      }
      if (open < 0.3) return
      if (t < 0.1) {                            // at rest: the dot pupil
        c.fillStyle = root.brand
        for (var py = 4; py <= 6; py++) for (var px = 5 + look; px <= 7 + look; px++) c.fillRect(px * s, py * s, d, d)
        return
      }
      var cx = 6 * s + d / 2, cy = mid * s + d / 2
      var ring = (t < 1.5 ? root.quint((t - 0.17) / 0.3) : 1 - 0.65 * smooth((t - 1.5) / 0.35)) * 13 * root.k
      var inked = root.quint((t - 0.36) / 0.3) * (1 - smooth((t - 1.4) / 0.25))
      c.fillStyle = root.brand
      for (var a = 0; a < 20; a++) spot(c, cx + ring * Math.cos(a * Math.PI / 10), cy + ring * Math.sin(a * Math.PI / 10), 2)
      if (inked > 0.01) {
        var spin = 5 * Math.PI * (1 - root.quint((t - 0.36) / 0.8)) + 1.2 * t + 3 * Math.PI * Math.pow(root.clamp01((t - 1.4) / 0.25), 2)
        var orbit = (3 + 5.5 * inked) * root.k
        for (var n = 0; n < 3; n++) {
          for (var m = 0; m < tomoeDots.length; m++) {
            if (inked < m * 0.2) break
            var at = spin + n * 2 * Math.PI / 3 - tomoeDots[m][0]
            spot(c, cx + orbit * Math.cos(at), cy + orbit * Math.sin(at), tomoeDots[m][1])
          }
        }
      }
      spot(c, cx, cy, 3)
    }
    Connections {
      target: root
      function onLightTChanged() { eye.requestPaint() }
    }
  }

  // Two sheets of paper. At a copy they fold away and a tick draws itself; a hover turns them red with a pop.
  component CopyIcon: Item {
    id: icon
    property real t: -1
    property color ink
    property color tickInk
    readonly property real s: 18 * root.k
    readonly property real tick: t < 0 ? 0 : root.quint(t / 0.26) * (1 - root.quint((t - 1.25) / 0.24))
    implicitWidth: s
    implicitHeight: s
    onTickChanged: tickPaint.requestPaint()
    onTickInkChanged: tickPaint.requestPaint()

    Item {
      anchors.fill: parent
      scale: 1 - icon.tick
      Rectangle {
        width: 13 * root.k; height: width
        radius: 3 * root.k
        color: "transparent"
        border.color: icon.ink
        border.width: 1.5 * root.k
      }
      Rectangle {
        x: 5 * root.k; y: x
        width: 13 * root.k; height: width
        radius: 3 * root.k
        color: root.ui.body
        border.color: icon.ink
        border.width: 1.5 * root.k
      }
    }
    Canvas {
      id: tickPaint
      anchors.fill: parent
      anchors.margins: -2 * root.k
      scale: 1 + 0.3 * Math.sin(Math.PI * root.clamp01(icon.t / 0.34)) * (icon.t >= 0 ? 1 : 0)
      onPaint: {
        var c = getContext("2d"), w = width, f = icon.tick
        c.clearRect(0, 0, w, height)
        if (f < 0.01) return
        var a = [0.18 * w, 0.54 * w], b = [0.41 * w, 0.77 * w], e = [0.84 * w, 0.26 * w]
        var knee = 0.32
        c.strokeStyle = icon.tickInk
        c.lineWidth = 2.4 * root.k
        c.lineCap = "round"
        c.lineJoin = "round"
        c.beginPath()
        c.moveTo(a[0], a[1])
        var p = Math.min(1, f / knee)
        c.lineTo(a[0] + (b[0] - a[0]) * p, a[1] + (b[1] - a[1]) * p)
        if (f > knee) {
          var q = (f - knee) / (1 - knee)
          c.lineTo(b[0] + (e[0] - b[0]) * q, b[1] + (e[1] - b[1]) * q)
        }
        c.stroke()
      }
    }
  }

  // ---- one surface per monitor: the frozen frame, the veil, and on the active one the box -----
  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      readonly property bool active: root.activeName === modelData.name
      readonly property real frameScale: frame.implicitWidth > 0 ? frame.implicitWidth / width : 1

      screen: modelData
      visible: root.frameStamp !== ""           // a hidden window never loads its Image, so map it empty first
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "tanuj-sharingan"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: active && visible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

      function takeOver() {
        root.screenW = win.width
        root.screenH = win.height
        root.frameWindow = stage.Window.window
        keys.forceActiveFocus()
      }
      onActiveChanged: if (active) takeOver()
      onVisibleChanged: if (visible && active) takeOver()
      onWidthChanged: if (active) root.screenW = width
      onHeightChanged: if (active) root.screenH = height

      Connections {
        target: stage.Window.window
        enabled: win.active
        function onAfterAnimating() {
          root.tick()
          if (root.animating) stage.Window.window.update()
        }
      }

      Item {
        id: stage
        anchors.fill: parent

        Image {
          id: frame
          anchors.fill: parent
          source: root.frameStamp ? "file://" + root.framePath(win.modelData.name) : ""
          asynchronous: true
          cache: false
          smooth: false
          visible: root.shown
          opacity: 1 - root.clamp01(root.closeT * 1.6 - 0.6)
          onStatusChanged: if (status === Image.Ready && root.frameStamp) root.frameReady()
        }

        ShaderEffect {
          anchors.fill: parent
          visible: root.shown
          fragmentShader: Qt.resolvedUrl("shaders/scrim.frag.qsb")
          opacity: 1 - root.closeT
          readonly property bool on: win.active && root.hasBox
          property size sizePx: Qt.size(width, height)
          property real dpr: stage.Window.window ? stage.Window.window.devicePixelRatio : 1
          property real k: root.k
          property vector4d hole: Qt.vector4d(root.boxX, root.boxY, root.boxX + root.boxW, root.boxY + root.boxH)
          property vector4d dock: Qt.vector4d(root.dockX, root.dockTop, root.dockX + root.dockW, root.dockTop + root.dockShown)
          property real holeR: 12 * root.k
          property real ring: root.ring
          property real dockR: 20 * root.k
          property real fillet: 16 * root.k
          property real hasBox: on ? 1 : 0
          property real dockOn: on && root.hasDock && root.dockShown > 1 ? 1 : 0
          property real dim: 0.46 * root.veil
          property real dotAlpha: 0.1 * root.veil
          property real scanX: root.boxX + root.boxW * (0.5 - 0.5 * Math.cos(root.scanClock * 3.4))
          property real scanAmt: on ? root.scanAmt * 0.85 : 0
          property color colBezel: root.ui.bezel
          property color colScan: root.brand
        }

        // the words, lit where they sit in the picture
        Item {
          id: reader
          x: root.boxX
          y: root.boxY
          width: root.boxW
          height: root.boxH
          visible: win.active && root.readable
          opacity: 1 - root.closeT
          clip: true

          Repeater {
            model: reader.visible ? root.lines : []

            Item {
              id: lineItem
              required property var modelData
              required property int index
              readonly property var line: modelData
              readonly property int n: line.text.length
              readonly property int blocks: root.blocksIn(line)
              readonly property real cellW: line.w / blocks
              readonly property real reached: root.igniteClock / root.blockMs - root.blockStarts[index]
              readonly property int ia: Math.max(0, Math.min(n, root.selA - line.start))
              readonly property int ib: Math.max(0, Math.min(n, root.selB - line.start))
              x: line.cx - line.w / 2
              y: line.cy - line.h / 2
              width: line.w
              height: line.h
              rotation: line.angle

              Rectangle {                       // every line the engine found: a soft mark, laid a block at a time
                width: Math.max(0, Math.min(lineItem.blocks, Math.ceil(lineItem.reached))) * lineItem.cellW
                height: parent.height
                radius: 2 * root.k
                color: Qt.alpha(root.brand, 0.14)
              }
              Rectangle {                       // the block being laid, bright until the next one lands
                visible: lineItem.reached > 0 && lineItem.reached < lineItem.blocks + 1
                x: (Math.min(lineItem.blocks, Math.ceil(lineItem.reached)) - 1) * lineItem.cellW
                width: lineItem.cellW
                height: parent.height
                radius: 2 * root.k
                color: Qt.alpha(root.brand, lineItem.reached > lineItem.blocks ? 0.5 * (lineItem.blocks + 1 - lineItem.reached) : 0.5)
              }
              Rectangle {                       // the selection
                visible: lineItem.ib > lineItem.ia
                x: visible ? lineItem.line.stops[lineItem.ia] : 0
                width: visible ? lineItem.line.stops[lineItem.ib] - x : 0
                height: parent.height
                radius: 2 * root.k
                color: Qt.alpha(root.brand, 0.5)
              }
            }
          }
        }

        // everything the pointer does on the screen, outside the dock
        MouseArea {
          id: surface
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.LeftButton | Qt.RightButton
          cursorShape: root.overText || root.selecting ? Qt.IBeamCursor : Qt.CrossCursor

          function inBox(m) {
            return root.hasBox && m.x >= root.boxX && m.x <= root.boxX + root.boxW && m.y >= root.boxY && m.y <= root.boxY + root.boxH
          }
          onPressed: function(m) {
            if (m.button === Qt.RightButton) {
              if (root.readable && inBox(m)) root.copyLineAt(m.x - root.boxX, m.y - root.boxY)
              else root.dismiss()
              return
            }
            root.activeName = win.modelData.name
            root.pressOutside = false
            if (root.stage === "pick") root.startBox(m.x, m.y)
            else if (root.readable && inBox(m)) root.pressBox(m.x - root.boxX, m.y - root.boxY)
            else if (!inBox(m)) { root.pressOutside = true; root.pressX = m.x; root.pressY = m.y }
          }
          onPositionChanged: function(m) {
            if (root.stage === "drag") root.dragBox(m.x, m.y, width, height)
            else if (root.pressOutside && pressed && Math.abs(m.x - root.pressX) + Math.abs(m.y - root.pressY) > 8 * root.k) {
              root.pressOutside = false
              var x = root.pressX, y = root.pressY
              root.startBox(x, y)
              root.dragBox(m.x, m.y, width, height)
            } else if (root.readable) root.moveBox(m.x - root.boxX, m.y - root.boxY)
          }
          onReleased: function(m) {
            root.selecting = false
            if (root.stage === "drag") root.endBox(win.frameScale)
            else if (root.pressOutside) { root.pressOutside = false; root.dismiss() }
          }
        }

        // the first instruction, on the bare bezel
        Rectangle {
          anchors.horizontalCenter: parent.horizontalCenter
          y: 36 * root.k
          visible: win.active && root.stage === "pick"
          width: pickHint.implicitWidth + 36 * root.k
          height: 36 * root.k
          radius: height / 2
          color: root.ui.bezel
          opacity: root.veil
          Row {
            id: pickHint
            anchors.centerIn: parent
            spacing: 14 * root.k
            MonoLabel { text: "Sharingan"; color: root.ui.bezelAccent }
            MonoLabel { text: "Drag over any text"; color: root.ui.bezelInk }
            MonoLabel { text: "Esc" }
          }
        }

        // the size chip that rides the corner of the box while it is drawn
        Rectangle {
          visible: win.active && root.stage === "drag"
          x: Math.min(win.width - width - 6 * root.k, root.boxX - root.ring)
          y: root.boxY + root.boxH + 10 * root.k + height > win.height ? root.boxY - height - 10 * root.k : root.boxY + root.boxH + 10 * root.k
          width: sizeChip.implicitWidth + 20 * root.k
          height: 24 * root.k
          radius: height / 2
          color: root.ui.bezel
          MonoLabel {
            id: sizeChip
            anchors.centerIn: parent
            color: root.ui.bezelInk
            font.features: { "tnum": 1 }
            text: Math.round(root.boxW) + " x " + Math.round(root.boxH)
          }
        }

        // ---- the dock ----------------------------------------------------------
        Item {
          id: dock
          x: root.dockX
          y: root.dockY
          width: root.dockW
          height: root.dockH
          visible: win.active && root.hasDock
          opacity: 1 - root.closeT

          readonly property real inner: root.dockW - root.pad * 2
          readonly property real seamY: root.pad + root.dockH - root.pad * 2 - root.stripH - root.pad / 2
          readonly property real seamX: root.pad + root.countW
          readonly property real halfBlock: root.gapOf("block") / 2
          readonly property real halfX: root.gapOf("x0") / 2
          readonly property real topEdge: root.dockSide === "below" ? 0 : root.dockH - root.dockShown
          readonly property real footEdge: root.dockSide === "below" ? root.dockShown : root.dockH
          readonly property point btn: Qt.point(root.dockW - root.pad - 30 * root.k, seamY - root.pad / 2 - 28 * root.k)

          function panel(x0, y0, x1, y1) {
            return Qt.vector4d(x0, Math.max(y0, topEdge + root.pad), x1, Math.min(y1, footEdge - root.pad))
          }

          MouseArea {                           // the dock is solid: nothing under it gets the pointer
            anchors.fill: parent
            acceptedButtons: Qt.AllButtons
            cursorShape: Qt.ArrowCursor
            hoverEnabled: true
          }

          ShaderEffect {
            anchors.fill: parent
            fragmentShader: Qt.resolvedUrl("shaders/goo.frag.qsb")
            property size sizePx: Qt.size(width, height)
            property real dpr: stage.Window.window ? stage.Window.window.devicePixelRatio : 1
            property real k: root.k
            property real rr: 18 * root.k
            property real dotAlpha: 0.55 * root.clamp01((root.dockClock - root.pulls.x0) / 200)
            property color colBody: root.ui.body
            property color colDot: root.ui.line
            property color colFlood: Qt.rgba(root.ui.accent.r, root.ui.accent.g, root.ui.accent.b, root.floodA)
            property vector3d flood: Qt.vector3d(dock.btn.x, dock.btn.y, root.floodR)
            property vector4d pText: dock.panel(root.pad, root.pad, root.dockW - root.pad, dock.seamY - dock.halfBlock)
            property vector4d pCount: dock.panel(root.pad, dock.seamY + dock.halfBlock, dock.seamX - dock.halfX, root.dockH - root.pad)
            property vector4d pStrip: dock.panel(dock.seamX + dock.halfX, dock.seamY + dock.halfBlock, root.dockW - root.pad, root.dockH - root.pad)
            property point kBlock: Qt.point(40 * root.k, root.tearOf("block"))
            property point kX0: Qt.point(40 * root.k, root.tearOf("x0"))
          }

          // everything below is clipped to the part of the dock that has arrived
          Item {
            x: 0
            y: dock.topEdge
            width: root.dockW
            height: Math.max(0, root.dockShown)
            clip: true

            Item {
              y: -dock.topEdge
              width: root.dockW
              height: root.dockH
              opacity: root.clamp01((root.dockClock - 300) / 220)

              // what the engine read; selecting here is selecting on the picture
              Item {
                id: textPanel
                x: root.pad + 18 * root.k
                y: root.pad + 12 * root.k
                width: dock.inner - 18 * root.k - 58 * root.k
                height: dock.seamY - root.pad / 2 - y - 8 * root.k

                MonoLabel {
                  id: statusLine
                  anchors.left: parent.left
                  anchors.top: parent.top
                  visible: !root.readable
                  color: root.stage === "failed" ? root.ui.accentInk : root.ui.ink2
                  text: root.stage === "reading" ? "Reading"
                    : root.stage === "empty" ? "No text in this box. Draw another"
                    : root.stage === "failed" ? "The OCR engine failed. Draw again" : ""
                  opacity: root.stage === "reading" ? 0.55 + 0.45 * Math.sin(root.scanClock * 5) : 1
                }

                Flickable {
                  id: scroller
                  anchors.fill: parent
                  visible: root.readable
                  opacity: 1 - root.floodA * root.clamp01(root.floodT / 120)
                  clip: true
                  interactive: false
                  contentWidth: width
                  contentHeight: preview.implicitHeight

                  TextEdit {
                    id: preview
                    width: scroller.width
                    readOnly: true
                    selectByMouse: false               // the MouseArea below drives root's range instead
                    persistentSelection: true
                    activeFocusOnPress: false
                    wrapMode: TextEdit.Wrap
                    textFormat: TextEdit.PlainText
                    text: root.fullText
                    color: root.ui.ink
                    selectionColor: root.ui.accent
                    selectedTextColor: root.ui.accentFg
                    font.family: root.ui.mono
                    font.pixelSize: 11 * root.k

                    Connections {
                      target: root
                      function onSelAChanged() { preview.syncFromRange() }
                      function onSelBChanged() { preview.syncFromRange() }
                    }
                    function syncFromRange() {
                      if (selectionStart === root.selA && selectionEnd === root.selB) return
                      if (root.selB > root.selA) select(root.selA, root.selB)
                      else deselect()
                      var r = positionToRectangle(root.selA)
                      if (r.y < scroller.contentY) scroller.contentY = r.y
                      else if (r.y + r.height > scroller.contentY + scroller.height) scroller.contentY = r.y + r.height - scroller.height
                    }
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  enabled: root.readable
                  cursorShape: Qt.IBeamCursor
                  function chrAt(m) { return preview.positionAt(m.x, m.y + scroller.contentY) }
                  onPressed: function(m) { root.pressText(chrAt(m)) }
                  onPositionChanged: function(m) { if (root.selecting) root.setSel(root.anchorChar, chrAt(m)) }
                  onReleased: root.selecting = false
                  onWheel: function(w) {
                    var most = Math.max(0, scroller.contentHeight - scroller.height)
                    scroller.contentY = Math.max(0, Math.min(most, scroller.contentY - w.angleDelta.y / 2))
                  }
                }
              }

              // how much is about to be copied
              Item {
                x: root.pad + 18 * root.k
                y: dock.seamY + root.pad / 2
                width: root.countW - 18 * root.k
                height: root.stripH
                Text {
                  id: countNum
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.verticalCenterOffset: -7 * root.k
                  text: root.wordCount < 10 ? "0" + root.wordCount : String(root.wordCount)
                  color: root.ui.ink
                  font.family: root.ui.sans
                  font.pixelSize: 34 * root.k
                  font.weight: Font.Light
                  font.features: { "tnum": 1 }
                  scale: 1 + 0.1 * root.kick
                  transformOrigin: Item.Left
                }
                MonoLabel {
                  anchors.left: parent.left
                  anchors.top: countNum.bottom
                  anchors.topMargin: -4 * root.k
                  text: root.hasSel ? "of " + root.totalWords + " words" : "words"
                }
                ReadingEye {
                  anchors.right: parent.right
                  anchors.rightMargin: 14 * root.k
                  anchors.verticalCenter: parent.verticalCenter
                  look: root.stage === "reading" ? Math.round(3 * Math.sin(root.scanClock * 3.4 - Math.PI / 2)) : 0
                  t: root.eyeT
                }
              }

              // what Copy will take: one capsule, one sliding pill; its segments are shortcuts
              Row {
                x: dock.seamX + root.pad / 2 + 14 * root.k
                y: dock.seamY + root.pad / 2 + (root.stripH - height) / 2
                spacing: 14 * root.k

                Item {
                  id: capsule
                  width: 164 * root.k
                  height: 30 * root.k
                  anchors.verticalCenter: parent.verticalCenter
                  Rectangle { anchors.fill: parent; radius: height / 2; color: root.ui.sub }
                  Rectangle {
                    x: root.hasSel ? parent.width / 2 : 0
                    width: parent.width / 2
                    height: parent.height
                    radius: height / 2
                    color: root.ui.accent
                    Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutQuint } }
                  }
                  Row {
                    anchors.fill: parent
                    Repeater {
                      model: ["All", "Selected"]
                      Item {
                        id: seg
                        required property string modelData
                        required property int index
                        width: capsule.width / 2
                        height: capsule.height
                        MonoLabel {
                          anchors.centerIn: parent
                          text: seg.modelData
                          font.letterSpacing: 0.8 * root.k
                          color: (seg.index === 1) === root.hasSel ? root.ui.accentFg : root.ui.mute
                        }
                        MouseArea {
                          anchors.fill: parent
                          enabled: root.readable
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            if (seg.index === 0) root.setSel(0, 0)
                            else if (!root.hasSel) root.setSel(0, root.fullText.length)
                          }
                        }
                      }
                    }
                  }
                }
                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: 2 * root.k
                  Row {
                    spacing: 8 * root.k
                    Row {                               // ten cells, the last one partly lit
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: 2 * root.k
                      Repeater {
                        model: 10
                        Rectangle {
                          required property int index
                          width: 4 * root.k
                          height: 8 * root.k
                          radius: 1 * root.k
                          color: root.ui.line
                          Rectangle {
                            anchors.fill: parent
                            radius: parent.radius
                            color: root.ui.accent
                            opacity: root.clamp01(root.confShown / 10 - parent.index)
                          }
                        }
                      }
                    }
                    MonoLabel {
                      color: root.readable && root.confLow ? root.ui.accentInk : root.ui.ink2
                      font.features: { "tnum": 1 }
                      text: !root.readable ? "Confidence" : Math.round(root.confShown) + "% " + (root.confLow ? "unsure" : "confident")
                    }
                  }
                  MonoLabel {
                    text: (root.engineName === "TESSERACT" ? "Tesseract" : "Sharingan") + (root.readMs > 0 ? "  " + (root.readMs / 1000).toFixed(1) + " s" : "")
                  }
                  MonoLabel { text: "Ctrl C  /  Enter closes" }
                }
              }

              // the flood's word
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                y: (dock.seamY - height) / 2 + root.pad
                text: "COPIED"
                opacity: root.floodA * root.clamp01(root.floodT / 220)
                color: root.ui.accentFg
                font.family: root.ui.sans
                font.pixelSize: 34 * root.k
                font.weight: Font.Light
              }
            }
          }

          // the one action, in the corner of the text it copies
          Item {
            width: 40 * root.k
            height: width
            x: dock.btn.x - width / 2
            y: dock.btn.y - height / 2
            scale: root.iconIn

            CopyIcon {
              anchors.centerIn: parent
              t: root.eyeT
              ink: !root.readable ? root.ui.mute : copyMouse.containsMouse ? root.ui.accentInk : root.ui.ink2
              tickInk: root.mix(root.ui.accentInk, root.ui.accentFg, root.floodA)
              scale: copyMouse.pressed ? 0.88 : copyMouse.containsMouse ? 1.24 : 1
              Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutBack; easing.overshoot: 4 } }
              Behavior on ink { ColorAnimation { duration: 130 } }
            }
            MouseArea {
              id: copyMouse
              anchors.fill: parent
              hoverEnabled: true
              enabled: root.readable
              cursorShape: Qt.PointingHandCursor
              onClicked: root.copy(false)
            }
          }
        }

        Item {
          id: keys
          focus: true
          Keys.onPressed: function(event) { root.handleKey(event) }
        }
      }
    }
  }
}
