#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
OCR_ROOT="$HOME/Library/Application Support/Shiori/OCR"
LEGACY_ROOT="$HOME/Library/Application Support/KedaTranslate"
if [[ ! -e "${OCR_ROOT:h}" && -d "$LEGACY_ROOT" ]]; then
  mv "$LEGACY_ROOT" "${OCR_ROOT:h}"
fi
if [[ ! -x "$OCR_ROOT/venv/bin/python" ]]; then
  uv venv --python 3.12 "$OCR_ROOT/venv"
fi
uv pip install --python "$OCR_ROOT/venv/bin/python" -r Resources/ocr-requirements.txt
"$OCR_ROOT/venv/bin/python" Scripts/setup_ocr.py
