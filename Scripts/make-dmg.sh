#!/bin/bash
# dist/Mobius.app → dist/Mobius-<version>.dmg (드래그로 Applications에 설치하는 배포용 이미지)
#
# 주의: 이 앱은 자체서명(Mobius Dev Signing) 또는 ad-hoc 서명이다. Developer ID + Apple 공증이
# 없으므로, 다른 맥에서 이 DMG를 열면 Gatekeeper가 "확인되지 않은 개발자"로 실행을 막는다.
# → 받은 사람은 앱을 우클릭 → '열기'(또는 시스템 설정 > 개인정보 보호 및 보안 > '확인 없이 열기')로
#   한 번만 허용하면 된다. 개인/자가 배포용 이미지다.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1) 앱 번들 빌드/서명
Scripts/make-app.sh

APP="dist/Mobius.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
DMG="dist/Mobius-$VERSION.dmg"

# 2) 드래그 설치 레이아웃(앱 + Applications 심볼릭 링크)을 스테이징에 구성
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/Mobius.app"
ln -s /Applications "$STAGING/Applications"

# 3) 압축 DMG 생성
rm -f "$DMG"
hdiutil create \
  -volname "Mobius" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

echo "OK: $DMG  ($(du -h "$DMG" | cut -f1))"
echo "GitHub 릴리스: gh release create v$VERSION \"$DMG\" --title \"Mobius v$VERSION\" --notes \"...\""
