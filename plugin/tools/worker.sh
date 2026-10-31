#!/bin/bash
# Starts the OCR worker in its venv; ocr.py falls back to tesseract if that venv is gone or broken.
py="${XDG_DATA_HOME:-$HOME/.local/share}/tanuj-sharingan/venv/bin/python"
[[ -x $py ]] || py=/usr/bin/python3
exec "$py" "$(dirname "$0")/ocr.py"
