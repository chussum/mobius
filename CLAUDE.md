# Mobius (뫼비우스) — Claude 계정 매니저

Claude Code CLI + Claude Desktop 계정을 전환/자동 fallback 하는 macOS 메뉴바 앱 + `mobius` CLI.
Swift Package (SwiftUI, macOS 14+). primary 소진 → fallback 자동 전환 → primary 회복 시 자동 복귀.

> **이 파일은 항상 최신 상태로 유지한다.** 구조·핵심 사실·실패 기록이 바뀌면 같은 커밋에서 갱신할 것.

## 빌드 / 실행

```bash
swift test                    # 유닛 테스트 (MobiusCore)
swift build                   # 컴파일 확인
Scripts/make-app.sh           # dist/Mobius.app 번들 조립 + 서명
Scripts/make-dmg.sh           # dist/Mobius-<ver>.dmg 배포 이미지 (드래그 설치)
open dist/Mobius.app          # 실행 (메뉴바 ∞ 아이콘)
Scripts/setup-signing.sh      # (1회) 고정 서명 인증서 생성 — 아래 '서명' 참조
```

## 구조

```
Sources/MobiusCore/       앱·CLI 공유 코어 (전부 의존성 주입 → 테스트 가능)
  MobiusEnvironment.swift  모든 경로 컨테이너 (MOBIUS_HOME 오버라이드)
  Models.swift             AccountProfile / AccountsFile / CredentialsSnapshot / RateLimitInfo
  KeychainClient.swift     SystemKeychain + InMemoryKeychain(테스트)
  ClaudeConfigIO.swift     Claude 자격증명 읽기/쓰기 (★ 아래 '진실의 원천' 필독)
  AccountStore.swift       프로필 영속(accounts.json) + 비밀 스냅샷(0600 파일)
  Switcher.swift           전환/되저장/롤백/reconcile/adopt (★ liveIsStable 게이팅)
  RateLimitParser.swift    세션 로그 rate-limit 이벤트 파서 (실측 기반)
  SessionLogWatcher.swift  ~/.claude/projects tail (네트워크 0)
  AutoSwitchEngine.swift   순수 상태머신 (쿨다운/마진/autoSwitchedFromPrimary)
  UsageFetcher.swift       usage 엔드포인트 조회 (게이지용, 팝오버 열 때만)
Sources/mobius/           CLI (list/switch/status/capture/auto)
Sources/MobiusApp/        SwiftUI 메뉴바 앱 + AppState + Views/ + LoginFlow + DesktopCoordinator
```

## 핵심 사실 (실측으로 확인 — 추측 금지)

### ★ 진실의 원천: 자격증명 토큰은 Keychain, 이메일은 ~/.claude.json
- **토큰**: Keychain `Claude Code-credentials` 가 진실. 이 환경의 Claude Code는
  최신 토큰을 Keychain에만 쓰고 `~/.claude/.credentials.json` **파일은 갱신하지 않는다(낡음)**.
  → `readLiveSnapshot()`은 **반드시 Keychain 우선**. 파일은 Keychain이 빈 경우의 폴백일 뿐.
- **이메일/계정 메타**: `~/.claude.json` 의 `oauthAccount.emailAddress`. 자격증명 blob에는 계정
  식별자가 **없다** (accessToken/refreshToken/expiresAt/subscriptionType 뿐).
- **전환 = 3곳 스왑**: Keychain + .credentials.json + ~/.claude.json 의 oauthAccount.

### 사용량 엔드포인트
- `GET https://api.anthropic.com/api/oauth/usage`, 헤더 `Authorization: Bearer <token>` +
  `anthropic-beta: oauth-2025-04-20`. 응답: `five_hour.{utilization, resets_at}`,
  `seven_day.{...}` (utilization=백분율, resets_at=ISO8601 마이크로초).
- 게이지는 **팝오버 열 때만** 조회(캐시 4분). 상시 폴링 없음 → 계정 리스크 최소화.

### macOS 26 (Tahoe) 환경
- 메뉴바 아이콘은 Control Center가 호스팅 — CGWindowList의 layer/owner로 존재 확인이 어려움.
- **Bartender 같은 메뉴바 관리 앱이 새 앱 아이콘을 자동 숨김** → 안 보이면 Bartender 설정에서 표시.
- 서명 안 된/ad-hoc 앱도 실행되지만 Keychain ACL이 서명 정체성에 묶임.

### 서명 (Keychain 승인창 영구 방지)
- ad-hoc 서명(`-s -`)은 **리빌드마다 정체성이 바뀌어** "항상 허용"이 매번 리셋됨.
- `Scripts/setup-signing.sh`로 고정 인증서 `Mobius Dev Signing` 생성 → make-app.sh가 자동 사용.
- 고정 서명 + 아래 '비밀은 파일' 조합으로 승인창이 사실상 사라짐.

### 비밀 스냅샷은 Keychain이 아니라 0600 파일
- 계정별 스냅샷은 `~/Library/Application Support/Mobius/secrets/<uuid>.json` (0600).
- Claude Code 자신도 토큰을 파일(.credentials.json 0600)에 두므로 동일 보안 수준이고,
  Keychain에 두면 계정 수 × 접근마다 승인창이 떠서 UX가 망가진다.
- 구버전 Keychain 항목(`Mobius-account-*`)은 `secret()`에서 발견 시 파일로 자동 이관 후 삭제.

## 실패 기록 (같은 실수 반복 금지)

1. **파일 우선 읽기로 바꿔 자격증명 오염** — "Keychain 승인창을 줄이자"고 `readLiveSnapshot()`을
   .credentials.json 파일 우선으로 바꿨더니, **낡은 파일 토큰(fore.st) + 최신 이메일(flosdor)**이
   짝지어져 flosdor 프로필에 fore.st 토큰이 저장됨. 사용자 라이브 로그인까지 오염됨.
   → 교훈: **토큰의 진실은 Keychain**. 파일은 낡을 수 있다. 승인창은 '고정 서명 + 비밀 파일화 +
   변화 시에만 Keychain 접근'으로 줄이고, 라이브 토큰 읽기는 Keychain을 포기하지 말 것.
2. **비원자 갱신 레이스** — 로그인/전환 중 토큰(Keychain)과 이메일(~/.claude.json)이 서로 다른
   시점에 갱신되는 찰나에 읽으면 짝이 안 맞음. → `ClaudeConfigIO.liveIsStable()`로 최근 2초 내
   수정 시 저장 계열 연산(resave/adopt/reconcile) 스킵. Switcher.stabilityWindow(테스트는 0).
3. **매 틱 Keychain 접근으로 승인창 폭탄** — reconcile이 15초마다 readLiveSnapshot(Keychain) 호출.
   → 이메일(.claude.json, 승인창 없음)로 먼저 판별하고, **활성 계정이 바뀐 경우에만** Keychain 접근.
3b. **guard 조건 평가 순서로 매 틱 Keychain 읽기** — `adoptLiveAccountIfUnregistered`의 guard가
   `readLiveSnapshot()`(Keychain)을 "이미 등록됐는지" 검사보다 **먼저** 평가해, 이미 등록된
   상태에서도 15초마다 Keychain을 읽어 승인창이 떴다. → 값싼 조건(이메일·등록여부)을 먼저 통과시키고
   Keychain 읽기는 정말 필요할 때만. **guard/&& 는 왼쪽부터 평가된다 — 비싼 부작용은 뒤로.**
4. **`security dump-keychain` 절대 금지** — 모든 항목을 하나씩 열어 승인창이 수십 개 쏟아짐.
   특정 항목만 `find-generic-password`(메타데이터) 또는 `-w`(값, 1회 승인)로 접근.
   실제로 이걸 돌려 승인창 폭탄을 유발했고, SIGKILL한 뒤에도 SecurityAgent가 멈춘 요청을
   계속 재표시했다. 키체인 진단은 앱 코드 로깅으로 하고 CLI로 키체인을 훑지 말 것.
4b. **"앱이 켜지면 승인창이 뜬다"의 진짜 범인은 codesign이었음 (오귀인 주의)** — `make-app.sh`의
   `codesign -s "Mobius Dev Signing"`이 서명용 **개인키**를 로그인 키체인에서 꺼내며 프롬프트를
   띄운다. 빌드+실행(open)을 붙여 돌리니 "앱 실행이 원인"처럼 보였다. **검증: SystemKeychain.read에
   추적 로깅 → 앱 45초 실행 중 호출 0회 = 앱은 키체인 무접근 확정.** 빌드/서명/security 없이
   앱만 관찰해야 앱의 진짜 동작이 보인다. 사용자는 빌드/서명을 안 하므로 이 프롬프트를 안 겪는다.
   교훈: 상관관계(≈타이밍)를 인과로 단정하지 말고, 단일 관문(SystemKeychain.read 등)에 계측해
   호출 여부를 직접 확인할 것.
5. **LSUIElement 오진** — 메뉴바 아이콘 미표시를 LSUIElement 탓으로 추정했으나 실제 원인은
   Bartender였음. 간접 증거(CGWindowList)로 단정하지 말고 실제 화면/스크린샷으로 확인.
6. **SwiftUI SettingsLink는 accessory 앱에서 무반응** — `NSApp.activate` + `openSettings()`로 대체.
7. **계정 추가가 수동 코드 페이지에서 멈춤** — `claude auth login`은 터미널에 '코드 붙여넣기용'
   URL을 출력하고, '브라우저로 여는' URL만 자동 콜백(localhost)임. → `BROWSER` 환경변수에 후킹
   스크립트를 꽂아 자동 콜백 URL을 가로채 ephemeral 인증창에 띄운다 (LoginFlow.swift).
8. **로그인 창 닫힘=취소 오판** — 성공 페이지 확인 후 창 닫으면 취소로 처리돼 등록 실패.
   → 취소 신호 후 유예를 두고 완료 감지를 우선. 프로세스 종료 시 인증창 즉시 닫기.
9. **파일 mtime 기반 안정성 판정이 활성 claude 세션 때문에 영영 안 됨** — 로그인/전환의
   토큰/이메일 불일치를 막으려 "`.claude.json`이 N초간 idle이면 안정"으로 판정했더니,
   **실행 중인 claude 세션(이 대화 포함)이 `.claude.json`을 자주 써서** idle이 안 돼
   계정 추가·reconcile이 영영 완료 안 됨(사용자 관찰로 발견). → 파일 idle 대신 **값을 두 번
   읽어(간격 0.7s) 토큰+이메일이 일치할 때만** 인정하는 `readStableLiveSnapshot()`으로 대체.
   교훈: `~/.claude.json`은 "바쁜 파일"이다 — mtime을 안정성/변화 신호로 쓰지 말 것.

## QA / 진행 상황

- `docs/qa/m1-checklist.md` 에 수동 QA 항목. 사용자 실행 검증 진행 중.
- 미완: 실행 중 claude 세션 유지 여부 실측(전환 시), Desktop 실동작 QA.
- 후속 후보: needsReauth 자동 감지, accounts.json 파일 락.
- 2차 프로젝트(합의): 멀티 PC ~/.claude 세션 동기화 — 자격증명 제외, 별도 스펙.
