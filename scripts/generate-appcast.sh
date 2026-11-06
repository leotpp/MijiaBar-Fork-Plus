#!/bin/bash
# 用 Sparkle 私钥给 DMG 签名，输出网站与 Release 资产用的 appcast。
# VERSION / DMG_PATH：版本号与 DMG，支持 -unsigned.dmg
# SPARKLE_KEY：私钥路径（默认 ~/mijiabar-private/sparkle/eddsa_priv.key）
# RELEASE_REPO / APP_LINK：仓库与产品主页
# DOWNLOAD_URL_PREFIX / DOWNLOAD_URL：下载前缀与单个 enclosure URL
# APPCAST_PATH / RELEASE_APPCAST_PATH：默认 docs/appcast.xml / dist/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/fetch-sparkle.sh
SP=.build/sparkle/2.10.0
KEY="${SPARKLE_KEY:-$HOME/mijiabar-private/sparkle/eddsa_priv.key}"
[ -f "$KEY" ] || { echo "❌ 找不到 Sparkle 私钥: $KEY（切勿提交到仓库）"; exit 1; }

VERSION="${VERSION:-}"
DMG_PATH="${DMG_PATH:-}"
if [ -z "$DMG_PATH" ] && [ -n "$VERSION" ]; then
  DMG_PATH="dist/MijiaBar-$VERSION.dmg"
  [ -f "$DMG_PATH" ] || DMG_PATH="dist/MijiaBar-$VERSION-unsigned.dmg"
fi
if [ -z "$DMG_PATH" ]; then
  DMG_PATH=$(ls -t dist/MijiaBar-*.dmg 2>/dev/null | head -1 || true)
fi
[ -n "$DMG_PATH" ] && [ -f "$DMG_PATH" ] || { echo "❌ 找不到 DMG（设 DMG_PATH 或 VERSION）"; exit 1; }
ARCHIVE=$(basename "$DMG_PATH")
VERSION="${VERSION:-$(printf '%s' "$ARCHIVE" | sed -E 's/^MijiaBar-//; s/\.dmg$//; s/-unsigned$//')}"
RELEASE_REPO="${RELEASE_REPO:-leotpp/MijiaBar-Fork-Plus}"
APP_LINK="${APP_LINK:-https://github.com/$RELEASE_REPO}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-https://github.com/$RELEASE_REPO/releases/download/v$VERSION/}"
DOWNLOAD_URL="${DOWNLOAD_URL:-${DOWNLOAD_URL_PREFIX%/}/$ARCHIVE}"
APPCAST_PATH="${APPCAST_PATH:-docs/appcast.xml}"
RELEASE_APPCAST_PATH="${RELEASE_APPCAST_PATH:-dist/appcast.xml}"

STAGE=$(mktemp -d /tmp/mijiabar-appcast.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT
cp "$DMG_PATH" "$STAGE/$ARCHIVE"
NOTES="docs/release-notes/v$VERSION.md"
if [ -f "$NOTES" ]; then cp "$NOTES" "$STAGE/${ARCHIVE%.dmg}.md"; fi

"$SP/bin/generate_appcast" \
  --ed-key-file "$KEY" \
  --download-url-prefix "${DOWNLOAD_URL_PREFIX%/}/" \
  --link "$APP_LINK" \
  --embed-release-notes \
  -o "$STAGE/appcast.xml" \
  "$STAGE"

# 旧构建可能带上游公钥，generate_appcast 此时会省略签名；显式签档并核验。
SIGNATURE=$("$SP/bin/sign_update" --ed-key-file "$KEY" -p "$DMG_PATH")
"$SP/bin/sign_update" --verify --ed-key-file "$KEY" "$DMG_PATH" "$SIGNATURE"
python3 - "$STAGE/appcast.xml" "$DOWNLOAD_URL" "$SIGNATURE" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
sparkle = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', sparkle)
p = Path(sys.argv[1])
root = ET.fromstring(p.read_bytes())
enclosures = root.findall('./channel/item/enclosure')
if len(enclosures) != 1:
    sys.exit('❌ enclosure 数量不为 1')
enclosures[0].set('url', sys.argv[2])
enclosures[0].set(f'{{{sparkle}}}edSignature', sys.argv[3])
ET.ElementTree(root).write(p, encoding='utf-8', xml_declaration=True)
PY
mkdir -p "$(dirname "$APPCAST_PATH")" "$(dirname "$RELEASE_APPCAST_PATH")"
cp "$STAGE/appcast.xml" "$APPCAST_PATH"
cp "$STAGE/appcast.xml" "$RELEASE_APPCAST_PATH"
printf '✅ %s\n✅ %s\n' "$APPCAST_PATH" "$RELEASE_APPCAST_PATH"
