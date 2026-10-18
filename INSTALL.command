#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
python3 Scripts/install_app.py
