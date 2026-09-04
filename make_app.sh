#!/bin/bash
# Build the Nsz.app drag & drop GUI bundle.
# Usage: ./make_app.sh [ARCH]
#   ARCH = arm64 (default, matches this machine) | x86_64
#   e.g. ARCH=x86_64 ./make_app.sh
# Optional: Resources/AppIcon.icns and Resources/Background.* are
#           embedded automatically when present.
set -euo pipefail
cd "$(dirname "$0")"

ARCH="${ARCH:-$(uname -m)}"
case "$ARCH" in
  arm64|x86_64) ;;
  *) echo "ERROR: unsupported ARCH '$ARCH' (use arm64 or x86_64)" >&2; exit 1 ;;
esac

echo "==> swift build -c release --arch $ARCH"
swift build -c release --arch "$ARCH"

APP="build/Nsz.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

BIN=".build/release-$ARCH/nszgui"
[ -f "$BIN" ] || BIN=".build/release/nszgui"
cp "$BIN" "$APP/Contents/MacOS/Nsz"
chmod +x "$APP/Contents/MacOS/Nsz"

# embed icon if provided
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  ICON_KEY=""
fi

# embed optional window background image (Resources/Background.png|jpg|jpeg|svg)
for BGEXT in png jpg jpeg svg; do
  if [ -f "Resources/Background.$BGEXT" ]; then
    cp "Resources/Background.$BGEXT" "$APP/Contents/Resources/Background.$BGEXT"
    echo "==> Embedded window background: Background.$BGEXT"
    break
  fi
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>CFBundleExecutable</key><string>Nsz</string>
    <key>CFBundleIdentifier</key><string>com.biu.nszapp</string>
    <key>CFBundleName</key><string>Nsz</string>
    <key>CFBundleDisplayName</key><string>NSZ 解压</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    ${ICON_KEY}
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>NSZ/NCZ 压缩包</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.biu.nsz</string>
            </array>
        </dict>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.biu.nsz</string>
            <key>UTTypeDescription</key><string>NSZ/NCZ compressed title</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.data</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>nsz</string>
                    <string>ncz</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
PLIST

# PlistLint check
plutil -lint "$APP/Contents/Info.plist"

# ad-hoc codesign (required to launch on Apple Silicon)
codesign --force --sign - "$APP" 2>/dev/null

# register with LaunchServices so "Open With" finds it immediately (local only, ignored in CI)
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP" 2>/dev/null || true

# zip for distribution
cd build
ZIP="Nsz-${ARCH}.zip"
rm -f "$ZIP"
ditto -c -k --keepParent Nsz.app "$ZIP"
cd ..

echo "==> Built $APP (arch: $ARCH)"
echo "    Distribution zip: build/$ZIP"
echo "    Drag it to /Applications to install."
