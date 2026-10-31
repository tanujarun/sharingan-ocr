#!/usr/bin/env python3
"""OCR worker for tanuj.sharingan. One JSON request per stdin line, one JSON reply per stdout line:
{"id", "path", "x", "y", "w", "h", "scale"} in native pixels of the frozen frame, scale = native px per
logical px. Replies give each line in reading order, in logical px relative to the box:
{"text", "start", "cx", "cy", "w", "h", "angle", "stops", "conf"}; stops are the offsets along the line of
every character boundary, so a pointer position maps to a character; conf is [first char, end char, 0..1] per
word, so the panel can answer for any selection. A QR code in the box reads as one more line."""
import json
import math
import os
import subprocess
import sys
import tempfile
import time

OUT = sys.stdout
sys.stdout = sys.stderr            # the engines may print; only our replies go to the pipe
PAD = 24                           # the detector misses text that touches the image edge
LANGS = os.environ.get("OMARCHY_OCR_LANGS", "eng")


def stops_for(text, length, spans):
    """Character boundaries along a line. spans = (first char, end char, u0, u1) for each word; characters
    inside a word and the spaces between words are spread evenly between the anchors."""
    n = len(text)
    anchors = {0: 0.0, n: length}
    last = 0.0
    for c0, c1, u0, u1 in spans:
        u0, u1 = max(last, u0), max(last, u1)
        anchors[c0], anchors[c1] = u0, u1
        last = u1
    keys = sorted(anchors)
    stops = []
    for a, b in zip(keys, keys[1:]):
        for i in range(a, b):
            stops.append(anchors[a] + (anchors[b] - anchors[a]) * (i - a) / (b - a))
    stops.append(anchors[keys[-1]])
    return [round(s, 2) for s in stops]


def line_from(text, quad, words, scale, sure, ox=0.0, oy=0.0):
    """quad = TL, TR, BR, BL along the reading direction, native px. words = (text, quad, sure); sure = 0..1,
    and the line's own value covers a line with no words."""
    q = [((x + ox) / scale, (y + oy) / scale) for x, y in quad]
    dx, dy = q[1][0] - q[0][0], q[1][1] - q[0][1]
    length = math.hypot(dx, dy) or 1.0
    ux, uy = dx / length, dy / length
    height = math.hypot(q[3][0] - q[0][0], q[3][1] - q[0][1]) or 1.0
    spans, conf, cursor = [], [], 0
    for word, wq, word_sure in words:
        at = text.find(word, cursor)
        if at < 0 or not word:
            continue
        along = [(((x + ox) / scale - q[0][0]) * ux + ((y + oy) / scale - q[0][1]) * uy) for x, y in wq]
        spans.append((at, at + len(word), min(along), max(along)))
        conf.append([at, at + len(word), word_sure])
        cursor = at + len(word)
    return {
        "text": text,
        "cx": round(sum(p[0] for p in q) / 4, 2),
        "cy": round(sum(p[1] for p in q) / 4, 2),
        "w": round(length, 2),
        "h": round(height, 2),
        "angle": round(math.degrees(math.atan2(dy, dx)), 2),
        "stops": stops_for(text, length, spans),
        "conf": conf or [[0, len(text), sure]],
    }


def bbox(line):
    a = math.radians(line["angle"])
    hw = (abs(math.cos(a)) * line["w"] + abs(math.sin(a)) * line["h"]) / 2
    hh = (abs(math.sin(a)) * line["w"] + abs(math.cos(a)) * line["h"]) / 2
    return line["cx"] - hw, line["cy"] - hh, line["cx"] + hw, line["cy"] + hh


def tight(line):
    """bbox shrunk a little: detected boxes of neighbouring lines overlap by a pixel or two."""
    inset = 0.15 * min(line["h"], line["w"])
    x0, y0, x1, y1 = bbox(line)
    return x0 + inset, y0 + inset, x1 - inset, y1 - inset


def cut(items, axis, unit):
    """Splits items at the widest empty gap along an axis; returns (gap, before, after)."""
    spans = sorted(items, key=lambda it: tight(it)[axis])
    best, at, reach = 0.0, 0, tight(spans[0])[axis + 2]
    for i in range(1, len(spans)):
        box = tight(spans[i])
        if box[axis] - reach > best:
            best, at = box[axis] - reach, i
        reach = max(reach, box[axis + 2])
    return best / unit, spans[:at], spans[at:]


def rows(items, unit):
    """Lines that overlap in both directions: group them by the row their centres sit on."""
    groups = []
    for it in sorted(items, key=lambda it: it["cy"]):
        if groups and it["cy"] - groups[-1][0]["cy"] <= 0.5 * unit:
            groups[-1].append(it)
        else:
            groups.append([it])
    lines, seps = [], []
    for group in groups:
        group.sort(key=lambda it: it["cx"])
        lines += group
        seps += [" "] * (len(group) - 1) + ["\n"]
    return lines, seps[:-1]


def order(items):
    """Recursive XY cut: returns (lines, separators) in reading order. Columns win over rows when their gutter
    is the wider gap, so a two-column page is not read straight across."""
    if len(items) < 2:
        return list(items), []
    unit = sorted(min(it["h"], it["w"]) for it in items)[len(items) // 2]
    gap_x, left, right = cut(items, 0, unit)
    gap_y, above, below = cut(items, 1, unit)
    if gap_x >= 1.5 and gap_x >= gap_y:
        first, second, sep = left, right, "\n\n"
    elif gap_y > 0:
        first, second, sep = above, below, "\n\n" if gap_y > 1.2 else "\n"
    else:
        return rows(items, unit)
    a, sa = order(first)
    b, sb = order(second)
    return a + b, sa + [sep] + sb


class Rapid:
    name = "RAPIDOCR"

    def __init__(self):
        import cv2
        import numpy
        from rapidocr import RapidOCR
        self.cv2, self.np = cv2, numpy
        # no angle classifier: it turned clean lines upside down and read them as noise
        self.engine = RapidOCR(params={"Global.use_cls": False, "Global.log_level": "error"})
        self.engine(numpy.zeros((64, 256, 3), numpy.uint8))     # load the models while the user drags

    def upright(self, crop, box):
        """A tall box is vertical text, which may read either way up: try both and keep the better read."""
        x0, y0 = [int(max(0, v)) for v in box.min(axis=0)]
        x1, y1 = [int(v) for v in box.max(axis=0)]
        part = crop[y0:y1, x0:x1]
        best = ("", 0.0, None)
        for code, quad in ((self.cv2.ROTATE_90_CLOCKWISE, (3, 0, 1, 2)), (self.cv2.ROTATE_90_COUNTERCLOCKWISE, (1, 2, 3, 0))):
            r = self.engine(self.cv2.rotate(part, code), use_det=False, use_cls=False, use_rec=True)
            if r.txts and float(r.scores[0]) > best[1]:
                best = (r.txts[0], float(r.scores[0]), quad)
        return best

    def read(self, req):
        img = self.cv2.imread(req["path"])
        if img is None:
            raise RuntimeError("frozen frame is gone")
        x, y = int(req["x"]), int(req["y"])
        crop = img[y:y + int(req["h"]), x:x + int(req["w"])]
        crop = self.cv2.copyMakeBorder(crop, PAD, PAD, PAD, PAD, self.cv2.BORDER_REPLICATE)
        # these flags stick to the engine between calls, so every call names them
        r = self.engine(crop, use_det=True, use_cls=False, use_rec=True, return_word_box=True)
        lines = []
        if r.txts is None:
            return lines
        words = r.word_results or [()] * len(r.txts)
        for box, text, score, wr in zip(r.boxes, r.txts, r.scores, words):
            quad = [tuple(p) for p in box.tolist()]
            # the word and line scores disagree both ways, and either one low means a doubtful word; below 0.5 the
            # word scores overstate a little, above it they matched the share of characters read right (5438 words)
            wlist = [(w[0], w[2], round(min(float(score), float(w[1])), 3)) for w in wr]
            if math.dist(quad[0], quad[3]) > 1.4 * math.dist(quad[0], quad[1]):
                text, score, order4 = self.upright(crop, box)
                if not text:
                    continue
                quad, wlist = [quad[i] for i in order4], []
            if text.strip() and float(score) >= 0.5:
                lines.append(line_from(text, quad, wlist, req["scale"], round(float(score), 3), -PAD, -PAD))
        return lines


class Tesseract:
    name = "TESSERACT"

    def read(self, req):
        k = 2                               # tesseract loses thin UI text below this
        with tempfile.NamedTemporaryFile(suffix=".png") as tmp:
            subprocess.run(["magick", req["path"], "-crop", f"{req['w']}x{req['h']}+{req['x']}+{req['y']}", "+repage",
                            "-resize", f"{k * 100}%", tmp.name], check=True)
            tsv = subprocess.run(["tesseract", tmp.name, "stdout", "--oem", "1", "--psm", "6", "-l", LANGS,
                                  "--dpi", "300", "tsv"], check=True, capture_output=True, text=True).stdout
        groups = {}
        for row in tsv.splitlines()[1:]:
            f = row.split("\t")
            if len(f) == 12 and f[0] == "5" and f[11].strip() and float(f[10]) >= 40:
                groups.setdefault((f[2], f[3], f[4]), []).append((f[11], *map(int, f[6:10]), round(float(f[10]) / 100, 3)))
        lines = []
        for group in groups.values():
            x0 = min(g[1] for g in group)
            y0 = min(g[2] for g in group)
            x1 = max(g[1] + g[3] for g in group)
            y1 = max(g[2] + g[4] for g in group)
            words = [(g[0], [(g[1], g[2]), (g[1] + g[3], g[2]), (g[1] + g[3], g[2] + g[4]), (g[1], g[2] + g[4])], g[5]) for g in group]
            sure = round(sum(g[5] for g in group) / len(group), 3)
            lines.append(line_from(" ".join(g[0] for g in group), [(x0, y0), (x1, y0), (x1, y1), (x0, y1)], words, req["scale"] * k, sure))
        return lines


def read_codes(req):
    """QR codes in the box as lines; (lines, boxes) with boxes in logical px, to drop OCR noise read inside them.
    Tries the box as it is, inverted for light-on-dark codes, on a white margin for a box drawn tight around a code
    (the detector needs the quiet zone), then the same again enlarged for small codes."""
    try:
        import cv2
    except ImportError:                     # the tesseract fallback runs without OpenCV
        return [], []
    img = cv2.imread(req["path"])
    if img is None:
        return [], []
    x, y = int(req["x"]), int(req["y"])
    crop = img[y:y + int(req["h"]), x:x + int(req["w"])]
    white = (255, 255, 255)
    framed = [cv2.copyMakeBorder(crop, PAD, PAD, PAD, PAD, cv2.BORDER_REPLICATE)]
    framed += [255 - framed[0], cv2.copyMakeBorder(crop, PAD, PAD, PAD, PAD, cv2.BORDER_CONSTANT, value=white),
               cv2.copyMakeBorder(255 - crop, PAD, PAD, PAD, PAD, cv2.BORDER_CONSTANT, value=white)]
    detector = cv2.QRCodeDetectorAruco()
    for k in (1, 2, 3):
        if k > 1 and crop.shape[0] * crop.shape[1] * k * k > 16_000_000:
            break
        for picture in framed:
            if k > 1:
                picture = cv2.resize(picture, None, fx=k, fy=k, interpolation=cv2.INTER_NEAREST)
            try:
                ok, texts, points, _ = detector.detectAndDecodeMulti(picture)
            except cv2.error:
                continue
            found = [(t, p) for t, p in zip(texts, points if ok else []) if t]
            if found:
                lines = [line_from(t, [tuple(c / k for c in corner) for corner in p.tolist()], [], req["scale"], 1.0, -PAD, -PAD) for t, p in found]
                return lines, [bbox(line) for line in lines]
    return [], []


def outside(line, boxes):
    return not any(x0 <= line["cx"] <= x1 and y0 <= line["cy"] <= y1 for x0, y0, x1, y1 in boxes)


def reply(obj):
    OUT.write(json.dumps(obj) + "\n")               # ASCII: stdout may not be UTF-8 on Windows
    OUT.flush()


def main():
    try:
        engine = Rapid()
    except Exception as err:
        print("rapidocr unavailable:", err, file=sys.stderr)
        engine = Tesseract()
    reply({"ready": True, "engine": engine.name})
    for raw in sys.stdin:
        req = json.loads(raw)
        began = time.time()
        try:
            codes, boxes = read_codes(req)
            lines, seps = order(codes + [line for line in engine.read(req) if outside(line, boxes)])
            text = ""
            for i, line in enumerate(lines):
                line["start"] = len(text)
                text += line["text"] + (seps[i] if i < len(seps) else "")
            reply({"id": req["id"], "engine": engine.name, "ms": int((time.time() - began) * 1000), "lines": lines, "text": text, "codes": len(codes)})
        except Exception as err:
            reply({"id": req["id"], "engine": engine.name, "error": str(err)})


if __name__ == "__main__":
    main()
