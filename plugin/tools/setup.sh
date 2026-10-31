#!/bin/bash
# Installs the OCR engine (RapidOCR on onnxruntime, about 380 MB, CPU only) outside the plugin folder.
# Rerun this if the panel says TESSERACT: a Python upgrade breaks the venv.
set -e
dir="${XDG_DATA_HOME:-$HOME/.local/share}/tanuj-sharingan"
mkdir -p "$dir"
/usr/bin/python3 -m venv --clear "$dir/venv"
"$dir/venv/bin/pip" install --quiet --disable-pip-version-check -r "$(dirname "$0")/requirements.txt"
"$dir/venv/bin/python" -c "from rapidocr import RapidOCR; RapidOCR()"
echo "ready: $dir/venv"
