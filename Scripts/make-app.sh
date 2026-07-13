#!/bin/bash
# MobiusApp 실행파일 → dist/Mobius.app 번들 조립 + ad-hoc 서명
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP=dist/Mobius.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
# 주의: 기본 APFS는 대소문자 구분이 없어 "Mobius"와 "mobius"가 같은 파일로 충돌한다.
# 앱 실행파일은 MobiusApp으로 두고 CLI를 mobius로 유지한다
# (SettingsView의 Bundle.main.url(forAuxiliaryExecutable: "mobius")가 이 이름에 의존).
cp .build/release/MobiusApp "$APP/Contents/MacOS/MobiusApp"
cp .build/release/mobius "$APP/Contents/MacOS/mobius"
# 다국어 리소스 번들 (Bundle.module이 Contents/Resources에서 찾는다)
mkdir -p "$APP/Contents/Resources"
cp -R .build/release/Mobius_MobiusApp.bundle "$APP/Contents/Resources/"
# 앱 아이콘 (설정창을 열 때 독에 표시됨)
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>MobiusApp</string>
  <key>CFBundleIdentifier</key><string>dev.chussum.mobius</string>
  <key>CFBundleName</key><string>Mobius</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Mobius Contributors. MIT License.</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.2.3</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <!-- LSUIElement 미사용: macOS 26 Tahoe에서 LSUIElement 앱의 MenuBarExtra 아이콘이
       등록되지 않는 회귀가 있어(실측 확인), AppDelegate의 setActivationPolicy(.accessory)로 대체 -->
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# 서명 우선순위: Developer ID Application(공증 가능) > Mobius Dev Signing(자체서명) > ad-hoc.
# Developer ID가 있으면 하드닝 런타임 + 보안 타임스탬프로 서명 → Scripts/make-dmg.sh가 공증까지 한다.
# 없으면 기존 자체서명/ad-hoc 폴백(로컬 개발 빌드는 공증 없이 빠르게).
DEVID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}')
if [ -n "$DEVID" ]; then
  # 공증 필수 조건: --options runtime(하드닝 런타임) + --timestamp(Apple TSA, 네트워크 필요).
  # 중첩 Mach-O(mobius CLI)를 먼저 서명한 뒤 앱 번들을 서명한다 — --deep는 Apple 비권장이라
  # 개별 서명. 메인 실행파일 MobiusApp은 앱 번들 서명 시 함께 봉인된다.
  echo "🔏 Developer ID 서명 ($DEVID) + 하드닝 런타임"
  codesign --force --options runtime --timestamp -s "$DEVID" "$APP/Contents/MacOS/mobius"
  codesign --force --options runtime --timestamp -s "$DEVID" "$APP"
elif security find-identity -v -p codesigning | grep -q "Mobius Dev Signing"; then
  # 서명 실패(중복 인증서로 ambiguous 등)를 조용히 지나치면 linker-signed adhoc으로
  # 남아 전환마다 승인창이 뜬다 — 명시적으로 실패시킨다.
  codesign --force -s "Mobius Dev Signing" "$APP" || {
    echo "ERROR: 고정 서명 실패 — 'Mobius Dev Signing' 중복/신뢰 상태를 확인:"
    echo "  security find-certificate -a -c 'Mobius Dev Signing' -Z ~/Library/Keychains/login.keychain-db | grep SHA-1"
    exit 1
  }
else
  echo "⚠️  'Mobius Dev Signing' 인증서 없음 → ad-hoc 서명 폴백."
  echo "   ad-hoc은 리빌드마다 정체성이 바뀌어 Keychain '항상 허용'이 리셋된다"
  echo "   (전환 시 승인창 2회 재발). Scripts/setup-signing.sh 를 1회 실행할 것."
  codesign --force -s - "$APP"
fi
echo "OK: $APP (open $APP 으로 실행)"
