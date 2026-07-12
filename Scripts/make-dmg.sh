#!/bin/bash
# dist/Mobius.app → dist/Mobius-<version>.dmg (드래그로 Applications에 설치하는 배포용 이미지)
#
# 서명·공증 동작은 로그인 키체인 상태에 따라 자동 분기한다:
#  · Developer ID Application 인증서 + notarytool 프로파일(기본 이름 mobius-notary)이 있으면
#    → 앱·DMG를 Apple 공증 + staple 한다. 받는 사람은 경고 없이 더블클릭으로 바로 실행.
#  · 없으면 → 자체서명/ad-hoc 이미지(공증 없음). 받는 사람은 앱 우클릭 → '열기'(또는 시스템 설정
#    > 개인정보 보호 및 보안 > '확인 없이 열기')로 최초 1회만 허용. 개인/소스빌드용 이미지.
#
# 준비(1회): Developer ID 인증서 발급 후
#   xcrun notarytool store-credentials "mobius-notary" \
#     --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <앱 암호(App-Specific Password)>
# 프로파일 이름은 NOTARY_PROFILE 환경변수로 바꿀 수 있다. Apple ID·비밀번호는 키체인에만 저장되고
# 이 스크립트/리포에는 프로파일 '이름'만 남는다.
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-mobius-notary}"

# 1) 앱 번들 빌드/서명 (make-app.sh가 Developer ID 있으면 하드닝 런타임으로 서명)
Scripts/make-app.sh

APP="dist/Mobius.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo "0.1.0")
DMG="dist/Mobius-$VERSION.dmg"

# 공증 가능 여부 = Developer ID Application 인증서 존재 (make-app.sh의 서명 분기와 동일 기준)
DEVID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')

# 공증 헬퍼: $1 경로(zip 또는 dmg)를 제출하고 Accepted가 아니면 로그 안내 후 종료
notarize() {
  local target="$1" out status id
  echo "📤 공증 제출: $target (완료까지 대기…)"
  out=$(xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  echo "$out"
  status=$(echo "$out" | grep 'status:' | tail -1 | awk -F': ' '{print $2}' | xargs || true)
  if [ "$status" != "Accepted" ]; then
    id=$(echo "$out" | grep '  id:' | head -1 | awk -F': ' '{print $2}' | xargs || true)
    echo "❌ 공증 실패 (status: ${status:-unknown})."
    [ -n "$id" ] && echo "   상세 로그: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
    exit 1
  fi
}

# 2) (공증 경로) 앱을 먼저 공증·staple — DMG에서 앱을 끄집어내도 티켓을 지니도록.
if [ -n "$DEVID" ]; then
  ZIP="dist/Mobius-$VERSION.zip"
  # ditto = 공증용 zip 표준 도구(심볼릭 링크·메타데이터 보존). `zip`은 손상 위험.
  ditto -c -k --keepParent "$APP" "$ZIP"
  notarize "$ZIP"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  echo "✅ 앱 공증·staple 완료"
else
  echo "⚠️  Developer ID Application 인증서 없음 → 공증 생략(자체서명/ad-hoc 이미지)."
  echo "   받는 사람은 앱 우클릭 → '열기'로 최초 1회 허용해야 한다."
fi

# 3) 드래그 설치 레이아웃(앱 + Applications 심볼릭 링크)을 스테이징에 구성
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/Mobius.app"
ln -s /Applications "$STAGING/Applications"

# 4) 압축 DMG 생성
rm -f "$DMG"
hdiutil create \
  -volname "Mobius" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

# 5) (공증 경로) DMG 공증·staple + 검증
if [ -n "$DEVID" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "🔎 검증:"
  spctl -a -vvv "$APP" 2>&1 | sed 's/^/   /' || true
  xcrun stapler validate "$DMG" 2>&1 | sed 's/^/   /' || true
fi

echo "OK: $DMG  ($(du -h "$DMG" | cut -f1))"
echo "GitHub 릴리스: gh release create v$VERSION \"$DMG\" --title \"Mobius v$VERSION\" --notes \"...\""
