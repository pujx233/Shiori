#!/bin/zsh
set -euo pipefail
[[ $# -eq 4 ]] || exit 64
SHIORI_PID="$1"
SHIORI_NEW="$2"
SHIORI_APP="$3"
SHIORI_SUPPORT="$4"
[[ "$SHIORI_PID" == <-> && "${SHIORI_APP:t}" == Shiori.app ]] || exit 65
[[ "$SHIORI_NEW" == "$SHIORI_SUPPORT"/Updates/*/unpacked/Shiori-*/Shiori.app ]] || exit 65
for SHIORI_ATTEMPT in {1..120}; do
  if ! kill -0 "$SHIORI_PID" 2>/dev/null; then break; fi
  sleep 0.25
done
if kill -0 "$SHIORI_PID" 2>/dev/null; then exit 1; fi
SHIORI_BACKUP=$(mktemp -d "${SHIORI_APP:h}/.shiori-update.XXXXXX")
SHIORI_SUCCESS=0
trap 'if [[ "$SHIORI_SUCCESS" == 0 ]]; then
  if [[ -d "$SHIORI_BACKUP/previous.app" ]]; then
    if [[ -e "$SHIORI_APP" ]]; then mv "$SHIORI_APP" "$SHIORI_BACKUP/failed.app" || true; fi
    mv "$SHIORI_BACKUP/previous.app" "$SHIORI_APP" || true
  fi
  print "更新未完成，已保留原版本。请打开发布页重新下载。" > "$SHIORI_SUPPORT/UpdateError.txt"
  /usr/bin/open "$SHIORI_APP" || true
fi' EXIT
mv "$SHIORI_APP" "$SHIORI_BACKUP/previous.app"
mv "$SHIORI_NEW" "$SHIORI_APP"
/usr/bin/codesign --verify --deep --strict "$SHIORI_APP"
SHIORI_SUCCESS=1
rm -f "$SHIORI_SUPPORT/UpdateError.txt"
rm -rf "$SHIORI_BACKUP"
SHIORI_DOWNLOAD="${SHIORI_NEW:h:h:h}"
if [[ "$SHIORI_DOWNLOAD" == "$SHIORI_SUPPORT"/Updates/* ]]; then rm -rf "$SHIORI_DOWNLOAD"; fi
/usr/bin/open "$SHIORI_APP"
