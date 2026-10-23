#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/Shiori.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
# Keep Vision in its own stable executable: App/UI changes must not invalidate
# the system's compiled recognition-model cache.
xcrun swiftc -swift-version 5 -O -module-name ShioriVision -target arm64-apple-macosx14.0 \
  Sources/VisionRecognition.swift Sources/VisionHelperMain.swift \
  -framework AppKit -framework Vision -o "$APP/Contents/Helpers/ShioriVision"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 \
  Sources/Core.swift Sources/CodexSession.swift Sources/GoogleTranslation.swift Sources/TranslationPipeline.swift Sources/VisionRecognition.swift Sources/OCR.swift Sources/ReadingScope.swift Sources/Capture.swift Sources/BubbleCorrection.swift Sources/Overlay.swift Sources/App.swift Sources/main.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CryptoKit \
  -o "$APP/Contents/MacOS/Shiori"
cp Resources/translation.schema.json Resources/translator.txt Resources/ocr_worker.py Resources/MangaIcon.icns Resources/MangaIcon.png Resources/ThirdPartyNotices.txt "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.sai.Shiori</string>
<key>CFBundleName</key><string>Shiori</string>
<key>CFBundleDisplayName</key><string>Shiori</string>
<key>CFBundleExecutable</key><string>Shiori</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.3.1</string>
<key>CFBundleVersion</key><string>42</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>MangaIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>截取所选窗口中的漫画页面用于翻译。</string>
</dict></plist>
PLIST
if [[ -n "${MANGA_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$MANGA_SIGNING_IDENTITY" --timestamp=none --identifier local.sai.Shiori.Vision "$APP/Contents/Helpers/ShioriVision"
  codesign --force --sign "$MANGA_SIGNING_IDENTITY" --identifier local.sai.Shiori "$APP"
else
  python3 Scripts/sign_app.py "$APP"
fi
codesign --verify --deep --strict "$APP"
print "Built: $APP"
