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
  Sources/Core.swift Sources/CodexSession.swift Sources/GoogleTranslation.swift Sources/TranslationPipeline.swift Sources/VisionRecognition.swift Sources/OCR.swift Sources/ReadingScope.swift Sources/Capture.swift Sources/BubbleCorrection.swift Sources/ReadingExperience.swift Sources/ReaderControls.swift Sources/AppServices.swift Sources/ServicesPanel.swift Sources/Overlay.swift Sources/ShioriIcon.swift Sources/App.swift Sources/main.swift \
  -framework AppKit -framework ScreenCaptureKit -framework CryptoKit -framework Carbon \
  -o "$APP/Contents/MacOS/Shiori"
cp Resources/translation.schema.json Resources/translator.txt Resources/ocr_worker.py Resources/ShioriAppIcon.icns Resources/ShioriAppIcon.png Resources/ThirdPartyNotices.txt Resources/ocr-requirements.txt Resources/install_ocr.sh Resources/apply_update.sh Resources/UV-LICENSE-MIT.txt Resources/UV-LICENSE-APACHE.txt "$APP/Contents/Resources/"
cp Scripts/setup_ocr.py "$APP/Contents/Resources/"
UV_BINARY="${commands[uv]:-}"
[[ -x "$UV_BINARY" ]] || { print -u2 "构建需要已安装 uv。"; exit 1; }
rm -f "$APP/Contents/Helpers/ShioriUV"
cp -L "$UV_BINARY" "$APP/Contents/Helpers/ShioriUV"
chmod 755 "$APP/Contents/Helpers/ShioriUV"
rm -f "$APP/Contents/Resources/MangaIcon.icns" "$APP/Contents/Resources/MangaIcon.png" "$APP/Contents/Resources/ShioriIcon.icns" "$APP/Contents/Resources/ShioriIcon.png" "$APP/Contents/Resources/ShioriKanaIcon.icns" "$APP/Contents/Resources/ShioriKanaIcon.png"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.sai.Shiori</string>
<key>CFBundleName</key><string>Shiori</string>
<key>CFBundleDisplayName</key><string>Shiori</string>
<key>CFBundleExecutable</key><string>Shiori</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.5.0</string>
<key>CFBundleVersion</key><string>51</string>
<key>LSUIElement</key><true/>
<key>CFBundleIconFile</key><string>ShioriAppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>截取所选窗口中的漫画页面用于翻译。</string>
</dict></plist>
PLIST
if [[ -n "${MANGA_SIGNING_IDENTITY:-}" ]]; then
  codesign --force --sign "$MANGA_SIGNING_IDENTITY" --timestamp=none --identifier local.sai.Shiori.Vision "$APP/Contents/Helpers/ShioriVision"
  codesign --force --sign "$MANGA_SIGNING_IDENTITY" --timestamp=none --identifier local.sai.Shiori.UV "$APP/Contents/Helpers/ShioriUV"
  codesign --force --sign "$MANGA_SIGNING_IDENTITY" --identifier local.sai.Shiori "$APP"
else
  python3 Scripts/sign_app.py "$APP"
fi
codesign --verify --deep --strict "$APP"
print "Built: $APP"
