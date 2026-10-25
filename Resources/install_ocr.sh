#!/bin/zsh
set -euo pipefail
SHIORI_RESOURCES="${0:A:h}"
SHIORI_OCR_ROOT="${SHIORI_OCR_ROOT:-$HOME/Library/Application Support/Shiori/OCR}"
export SHIORI_OCR_ROOT UV_NO_CACHE=1
export UV_PYTHON_INSTALL_DIR="$SHIORI_OCR_ROOT/python"
export PYTHONUNBUFFERED=1 HF_HUB_DISABLE_XET=1
SHIORI_UV="$SHIORI_RESOURCES/../Helpers/ShioriUV"
if [[ ! -x "$SHIORI_UV" ]]; then
  SHIORI_UV="${commands[uv]:-}"
fi
if [[ ! -x "$SHIORI_UV" ]]; then
  print -u2 '找不到安装工具，请重新下载完整的 Shiori 安装包。'
  exit 1
fi
mkdir -p "$SHIORI_OCR_ROOT"
SHIORI_CHILD=''
trap 'if [[ -n "$SHIORI_CHILD" ]]; then kill -TERM "$SHIORI_CHILD" 2>/dev/null || true; fi' TERM INT EXIT
run_step() {
  "$@" &
  SHIORI_CHILD=$!
  wait "$SHIORI_CHILD"
  SHIORI_CHILD=''
}
print '{"message":"正在准备 Python 3.12…"}'
if [[ ! -x "$SHIORI_OCR_ROOT/venv/bin/python" ]]; then
  run_step "$SHIORI_UV" venv --python 3.12 "$SHIORI_OCR_ROOT/venv"
fi
print '{"message":"正在安装识字依赖…"}'
run_step "$SHIORI_UV" pip install --python "$SHIORI_OCR_ROOT/venv/bin/python" -r "$SHIORI_RESOURCES/ocr-requirements.txt"
print '{"message":"正在下载并校验识字与去字模型…"}'
exec "$SHIORI_OCR_ROOT/venv/bin/python" "$SHIORI_RESOURCES/setup_ocr.py"
