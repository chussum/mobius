# 빌드 · 서명 · 배포 (메인테이너용)

Mobius 릴리스 DMG를 만들고 배포하는 방법. 일반 사용자는 몰라도 되는 내부 문서다.

릴리스 DMG는 Apple **Developer ID Application** 인증서로 서명하고 **공증(notarization)** 까지
거쳐, 받는 사람이 "확인되지 않은 개발자" 경고 없이 바로 실행할 수 있게 한다. 빌드 스크립트가
로그인 키체인 상태를 보고 자동 분기한다 — 인증서가 없으면 자체서명/ad-hoc으로 빌드되고(개인용),
있으면 공증까지 한다.

> **핵심**: 서명만으로는 경고가 안 사라진다. **Developer ID 서명 + 공증**을 둘 다 해야 한다.
> Xcode 프로젝트(.xcodeproj)는 필요 없다 — SwiftPM으로 조립한 `.app`에 `codesign` +
> `xcrun notarytool` + `xcrun stapler`만 돌리면 된다.

## 최초 1회 준비

### 1. Developer ID Application 인증서 발급 (유료 Apple Developer Program 필요)

둘 중 하나:

- **Xcode 있으면**: Xcode → Settings → Accounts → Apple ID 추가 → Manage Certificates →
  `+` → **Developer ID Application**. 로그인 키체인에 인증서+개인키 생성.
- **Xcode 없으면**: Keychain Access → 인증서 지원 → *"인증 기관에서 인증서 요청"*(CSR 생성)
  → developer.apple.com → Certificates → `+` → **Developer ID Application** → CSR 업로드 →
  `.cer` 다운로드 → 더블클릭해 로그인 키체인에 설치.

확인:

```bash
security find-identity -v -p codesigning
# → "Developer ID Application: <이름> (TEAMID)" 가 보이면 성공. 괄호 안이 Team ID.
```

### 2. 공증 자격증명 저장 (키체인에만 저장 — 리포엔 안 들어감)

```bash
# appleid.apple.com → 로그인 및 보안 → '앱 암호'에서 App-Specific Password 발급 후:
xcrun notarytool store-credentials "mobius-notary" \
  --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <앱-암호>
```

프로파일 이름은 `NOTARY_PROFILE` 환경변수로 바꿀 수 있다. `xcrun notarytool --version` 으로
notarytool 사용 가능 여부(Xcode/CLT 13+)를 확인한다.

## 빌드 & 릴리스

```bash
Scripts/make-app.sh    # 앱 번들 조립 + (Developer ID 있으면) 하드닝 런타임 서명
Scripts/make-dmg.sh    # DMG 생성 + (자격증명 있으면) 앱·DMG 공증 + staple + 검증
gh release create v<버전> dist/Mobius-<버전>.dmg --title "Mobius v<버전>" --notes "..."
```

`make-dmg.sh` 는 앱을 먼저 공증·staple 한 뒤 DMG를 만들고 DMG도 공증·staple 한다(앱을 DMG에서
끄집어내도 티켓을 지니도록). 자격증명이 없으면 공증 단계를 건너뛰고 자체서명 이미지를 만든다.

### 검증

```bash
codesign -dvvv dist/Mobius.app          # Authority=Developer ID Application, flags에 runtime
spctl -a -vvv dist/Mobius.app           # → accepted, source=Notarized Developer ID
xcrun stapler validate dist/Mobius-<버전>.dmg
```

가장 확실한 검증은 **다른 Mac(또는 다른 사용자 계정)** 에서 DMG를 열어 경고 없이 실행되는지
보는 것이다. 빌드한 개발 머신은 이미 신뢰 상태라 오탐이 날 수 있다.

## 다른 Mac에서 빌드하기 (인증서 옮기기)

인증서 개인키와 공증 자격증명은 **비밀**이다 — git에 올리지 말고 아래처럼 옮긴다.

1. **인증서+개인키 내보내기** (기존 Mac): Keychain Access → 로그인 → *내 인증서* →
   `Developer ID Application: …` 우클릭 → **내보내기…** → `.p12`로 저장(**내보내기 암호 설정**).
2. **새 Mac에 설치**: `.p12` 더블클릭 → 로그인 키체인에 설치(암호 입력).
3. **공증 프로파일 재생성**: 위 `xcrun notarytool store-credentials …` 를 새 Mac에서 한 번 실행
   (앱 암호는 appleid.apple.com에서 새로 발급 가능).
4. 이후 `Scripts/make-dmg.sh` 가 동일하게 동작한다.

## 백업 & 보안

- `.p12`(개인키 포함)와 앱 암호는 **비밀번호 관리자나 암호화된 저장소**에 보관한다. **리포에
  커밋 금지.**
- 분실 시 developer.apple.com에서 인증서를 재발급하고 앱 암호를 다시 만들면 된다.
- 이 리포에 남는 건 스크립트 로직과 프로파일 **이름**(`mobius-notary`)뿐이며, Apple ID·비밀번호·
  개인키는 로컬 키체인에만 존재한다.

## 참고: 번들 ID & 하드닝 런타임

- 번들 ID는 `dev.chussum.mobius` (`Scripts/make-app.sh`). App Store와 달리 Developer ID 배포는
  ID 사전 등록이 불필요하다.
- 앱은 샌드박스가 아니고 `/usr/bin/security`·`claude`·Desktop 실행 등 자식 프로세스를 spawn하지만,
  하드닝 런타임은 자식 프로세스 spawn을 막지 않으므로 **엔titlement 파일 없이** 공증이 통과한다.
  (혹시 공증이 특정 항목을 거부하면 최소 엔titlement plist를 추가한다.)
