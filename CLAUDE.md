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
  SyncEngine.swift         멀티 Mac 동기화 (클라우드 폴더 미러, ★ 아래 '동기화 원칙')
  UpdateChecker.swift      GitHub 릴리스 업데이트 확인 (하루 1회)
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

### ★ OAuth 토큰 refresh (폴백 로그인 생사 판정 — claude 2.1.207 바이너리 실측)
- `POST https://platform.claude.com/v1/oauth/token`, `Content-Type: application/json`,
  body `{grant_type:"refresh_token", refresh_token, client_id:"9d1c250a-e61b-44d9-88ed-5944d1962f5e",
  scope:"<blob.scopes 공백조인>"}`. 200 → `{access_token, refresh_token(회전), expires_in,
  refresh_token_expires_in?, scope?}`.
- **★ User-Agent 필수**: URLSession 기본 UA면 서버가 **400 `invalid_request_error`
  "Invalid request format"** 로 거부하고, UA가 아예 없으면 **Cloudflare 403 code 1010**.
  claude와 동일 UA(`claude-cli/<ver> (external, cli)`)를 **세션 `httpAdditionalHeaders`로** 실어야
  통과한다(요청 setValue만으론 CFNetwork가 무시). UA 값 자체는 무관 — 있기만 하면 형식 통과.
- **판정 신호는 refresh 결과뿐**(모호한 usage 401 아님): 성공=살아있음(+토큰 회전 저장),
  `invalid_grant`=폐기(재로그인), 그 외 4xx/5xx/네트워크=transient(마킹 안 함, 오탐 방지).
- **빈 refresh 토큰**(`refreshToken:""`, 실측 fore.st 손상 스냅샷)은 nil로 취급 → 재로그인 유도.
  빈 토큰을 그대로 보내면 서버가 `invalid_request_error`(← invalid_grant 아님, 만료가 아니라 형식).
- **활성 계정은 절대 refresh 안 함**(claude가 라이브 관리 → 동시 로테이션=세션 파괴).
  refresh는 **폴백 전용** + 회전 토큰 **원자 저장**(실패 시 needsReauth로 복구 유도).
- **트리거**: (1) 팝오버 = **네트워크 0 로컬 검사만**(빈/시간만료 refresh 토큰 즉시 플래그),
  (2) **자동 폴백 전환 직전** = 실제 refresh(onTick(A)가 매 틱 재시도 → 죽은 폴백 스킵→다음 자동),
  (3) **수동 전환(계정 클릭)** = 대상 계정 refresh 1회(살았는지+신선한 토큰), (4) **만료 임박
  자동 갱신** = 폴백의 refreshTokenExpiresAt가 3일 이내면 1시간 스윕·계정당 6시간 간격으로 미리
  refresh(안 쓰던 폴백이 몇 주 뒤 조용히 죽는 것 방지). refresh는 access·refresh 토큰과 두 만료를
  모두 갱신. → 매 팝오버 호출 없음 = 블락 위험 최소화.

### macOS 26 (Tahoe) 환경
- 메뉴바 아이콘은 Control Center가 호스팅 — CGWindowList의 layer/owner로 존재 확인이 어려움.
- **Bartender 같은 메뉴바 관리 앱이 새 앱 아이콘을 자동 숨김** → 안 보이면 Bartender 설정에서 표시.
- 서명 안 된/ad-hoc 앱도 실행되지만 Keychain ACL이 서명 정체성에 묶임.

### 서명 (Keychain 승인창 영구 방지)
- ad-hoc 서명(`-s -`)은 **리빌드마다 정체성이 바뀌어** "항상 허용"이 매번 리셋됨.
- `Scripts/setup-signing.sh`로 고정 인증서 `Mobius Dev Signing` 생성 → make-app.sh가 자동 사용.
- 고정 서명 + 아래 '비밀은 파일' 조합으로 승인창이 사실상 사라짐.

### Desktop 내장 Claude Code가 `security` CLI로 CLI 자격증명을 읽는다 (파티션 리스트)
- 최근 Claude Desktop은 Claude Code를 내장(`claude-code`, `cowork-enabled-cli-ops.json`)하며,
  **Desktop 실행 시 `/usr/bin/security`로 Keychain `Claude Code-credentials`를 읽는다.**
- 이 항목의 **파티션 리스트에 `apple-tool:`이 없으면** security 접근마다 **키체인 암호를
  요구하는 창**이 뜨고, 이 유형은 **'항상 허용'을 눌러도 절대 저장되지 않는다**
  (파티션 검사는 ACL과 별개). Desktop을 재실행할 때마다 2회씩 반복 (2026-07-11 실측).
- 1회 해결: `security set-generic-password-partition-list -S "apple-tool:,apple:"
  -s "Claude Code-credentials" -a $USER` (로그인 키체인 암호 필요. "(deprecated)" 문구는
  대화형 암호 입력 방식에 대한 경고일 뿐 — 이 명령이 파티션 수정의 유일한 수단).
- 주의: CLI 재로그인 등으로 항목이 **재생성되면 파티션이 리셋**되어 재적용 필요.
- ★ 더 치명적: **비-Apple 앱이 SecItemUpdate로 항목을 수정하면 macOS가 파티션 리스트를
  그 앱의 cdhash로 도장 찍는다(re-stamp).** Mobius가 네이티브 API로 토큰을 쓰면 전환할
  때마다 파티션이 `cdhash:MobiusApp`으로 리셋 → security 경유 읽기(CLI·Desktop)가 전부
  암호창 유발. → `SystemKeychain`은 **읽기·쓰기 모두 security CLI 경유**다
  (쓰기는 -i stdin으로 비밀 전달, 읽기는 -w stdout 파싱·exit 44=없음). 이러면 도장이
  `apple-tool:`로 찍혀 유지되고, 파티션 밖인 Mobius 자신도 창 없이 접근한다 (실패 기록 12).
- 파티션 리스트 실제 값 확인은 SecAccessCopyACLList의 `ACLAuthorizationPartitionID`
  ACL desc(hex plist)를 디코드하면 승인창 없이 볼 수 있다.

### Claude Desktop은 Squirrel(ShipIt) 자동업데이트 — 앱 종료 순간 번들 통째 교체
- 업데이트가 스테이징되어 있으면 **Desktop이 종료되는 순간** ShipIt이
  `/Applications/Claude.app`을 temp로 이동시키고 새 번들로 교체한다
  (`~/Library/Caches/com.anthropic.claudefordesktop.ShipIt/ShipIt_stderr.log`).
- 그래서 Desktop을 종료→재실행할 때는 반드시 ShipIt이 끝나길 기다려야 한다 —
  `DesktopCoordinator.launch()`의 `waitForUpdaterQuiescence()`가 담당 (실패 기록 10 참조).

### 비밀 스냅샷은 Keychain이 아니라 0600 파일
- 계정별 스냅샷은 `~/Library/Application Support/Mobius/secrets/<uuid>.json` (0600).
- Claude Code 자신도 토큰을 파일(.credentials.json 0600)에 두므로 동일 보안 수준이고,
  Keychain에 두면 계정 수 × 접근마다 승인창이 떠서 UX가 망가진다.
- 구버전 Keychain 항목(`Mobius-account-*`)은 `secret()`에서 발견 시 파일로 자동 이관 후 삭제.

### 멀티 Mac 동기화 원칙 (SyncEngine)
- 클라우드 **폴더**(iCloud `~/Library/Mobile Documents/com~apple~CloudDocs`,
  Google Drive `~/Library/CloudStorage/GoogleDrive-*`) 경유 — API·로그인 불필요.
- **절대 제외(하드코딩+테스트 보증)**: `*credential*`, `accounts.json`, `secrets/`.
  `~/.claude.json`은 동기화 루트 밖(계정 정보 포함)이라 애초에 대상 아님.
- 비교는 mtime(±2s)+size, 최신 승. busy(60초 내 수정) 스킵 — 단 **미래 mtime은 busy 아님**
  (머신 간 시계 오차, busy 오판 시 영원히 동기화 안 됨). 삭제는 tombstone+휴지통 30일 —
  즉시 삭제 금지. 머신별 manifest로 "내가 지운 것"과 "아직 안 받은 것"을 구분한다.
- 설정은 머신 로컬(UserDefaults) — 켠 Mac만 참여. 플러그인 목록 실측 파일명:
  `plugins/installed_plugins.json` + `known_marketplaces.json` (config.json 아님).

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

10. **Desktop 재실행이 ShipIt 업데이트와 레이스 → 키체인 승인창 폭풍** — Desktop 전환의
    `종료 → 스왑 → 즉시 재실행`이 종료 순간 시작되는 ShipIt 업데이트 적용과 겹치면,
    실행 중인 Desktop 프로세스의 번들이 디스크에서 이동/교체된다. 이 프로세스는 코드서명
    동적 검증이 깨져 **키체인 접근마다 승인창이 뜨고 '항상 허용'도 ACL에 저장되지 않는다**
    (사용자 실측: 항상 허용 눌러도 재발, 토글 꺼도 지속). 실측 근거: ShipIt 로그의
    `App Still Running Error`(우리가 재실행한 인스턴스가 업데이트를 막은 기록).
    → `launch()` 전에 ShipIt 대기 + `/Applications` 밖 번들 실행 금지. **회복은 재설치가
    아니라 Desktop 완전 종료 후 재실행이면 충분** — 승인창 원인을 키체인 항목/ACL 오염으로
    오귀인하지 말 것 (Mobius는 `Claude Safe Storage`를 아예 안 건드린다).

11. **"키체인 승인창" 하나에 원인이 3중으로 겹쳐 있었음 — 창의 요청자·문구부터 볼 것** —
    (a) Desktop 실행 시: `security`發 암호형 창 = 파티션 리스트 문제(핵심 사실 참조),
    (b) 계정 전환 시 2회/추가 시 3회: Mobius發 = **make-app.sh가 인증서 없음/서명 실패 시
    조용히 ad-hoc으로 남아** 리빌드마다 승인 리셋, (c) ShipIt 레이스(실패 기록 10).
    같은 "승인창"이라도 **요청 앱 이름과 창 유형(버튼형 vs 암호형)이 다르면 원인이 다르다.**
    파생 함정: setup-signing.sh가 비GUI 컨텍스트에서 osascript(관리자 권한) 실패 →
    재실행하면 같은 이름 인증서가 **중복 생성**되어 codesign이 ambiguous로 실패하는데,
    make-app.sh가 이를 무시하고 linker-signed adhoc으로 통과시켰다. → 두 스크립트 모두
    가드 추가(중복 시 신뢰 등록만 재시도 / 서명 실패 시 명시적 exit 1).

12. **파티션 리스트를 고쳐도 계속 리셋 — 범인은 Mobius의 SecItemUpdate** — 파티션을
    `apple-tool:,apple:`로 고쳐도 계정 전환만 하면 Desktop 내장 Claude Code의 security
    읽기가 다시 암호창을 띄웠다. ACL 덤프로 추적하니 파티션이 매번 `cdhash:<MobiusApp>`
    으로 되돌아가 있었고, 이 cdhash가 실행 중인 Mobius 빌드와 정확히 일치했다.
    **macOS는 비-Apple 앱이 항목을 수정하면 파티션을 수정자의 cdhash로 재도장한다.**
    '항상 허용'이 안 먹히던 진짜 이유 — 다음 전환(쓰기)이 승인 상태를 도로 밀어버림.
    → 쓰기를 security CLI 경유로 변경(KeychainClient.writeViaSecurityCLI).
    교훈: (1) 증상 관찰이 아니라 **상태(ACL/파티션)를 직접 덤프해 전후 비교**로 추적할 것.
    (2) 샌드박스 셸에서의 security 테스트는 GUI 세션과 판정이 달라 **착시를 만든다** —
    반드시 사용자 터미널/실제 앱 경로로 재현할 것.

13. **Codable 저장 구조에 필드 추가 → 구버전 accounts.json 디코드 실패 → 계정 유실** —
    `RateLimitInfo.modelScoped`·`AccountProfile.userPinned`를 추가했더니, 그 키가 없는
    기존 accounts.json이 **`keyNotFound`로 디코드 실패**했다. AppState는 이때 빈 스토어로
    폴백하는데, 이후 reconcile이 라이브 계정만 저장하며 **파일을 덮어써 fore.st가 영구
    유실**됐다(secret 파일이 남아 수동 복구). 합성 Codable은 non-optional 필드의 키가
    없으면 실패한다. → **저장되는 struct에 필드를 추가할 땐 반드시 관대한 `init(from:)`을
    함께 넣어** `decodeIfPresent(...) ?? 기본값`으로 구버전 파일을 읽는다(Models.swift).
    추가 방어: AccountStore.init은 디코드 실패 시 원본을 `accounts.corrupt.json`으로
    백업한 뒤 throw(빈 스토어가 덮어써도 복구 가능). 교훈: (1) 지속화 구조 변경은 항상
    하위호환 디코딩 + 마이그레이션 테스트를 동반한다. (2) "빈 폴백 후 저장"은 조용한
    데이터 파괴 경로다 — 로드 실패 시 원본을 먼저 지켜라. (3) 개발자는 잦은 빌드로 이 경로를
    바로 밟지만, **업데이트만 하는 사용자에게 그대로 터진다** — 릴리스 전 구파일 로드 필수 확인.

14. **폴백 refresh 400을 "토큰 만료"로 오귀인할 뻔 — 범인은 URLSession UA와 빈 토큰** —
    폴백 로그인 검증용 OAuth refresh가 계속 **400 `invalid_request_error` "Invalid request
    format"** 을 받았다. "토큰 만료 아니냐"는 추측이 자연스러웠지만 만료면 `invalid_grant`다
    (형식 거부 ≠ 폐기). 실측 계측(파일 로그 + **더미 토큰 python 요청**으로 헤더 조합 격리)으로
    두 원인을 밝혔다: (a) **URLSession 기본 UA를 서버가 형식 거부** — claude UA를 요청 setValue만
    하면 CFNetwork가 무시하므로 **세션 `httpAdditionalHeaders`로** 실어야 한다(UA 없으면 Cloudflare
    403 1010, 있으면 값 무관하게 통과). (b) **fore.st 스냅샷의 refreshToken이 빈 문자열** — 빈
    토큰을 보내 형식 거부됐다. 교훈: (1) 4xx는 **본문의 error type을 봐라**(invalid_request vs
    invalid_grant는 원인이 딴판). (2) URLSession vs 참조 클라이언트(python/curl)를 **더미 자격으로**
    비교하면 형식/헤더 문제를 계정 위험 없이 격리할 수 있다. (3) 저장 스냅샷은 **빈 필드**로도 손상될
    수 있으니 `!isEmpty` 가드로 nil 취급해 재로그인 유도.

## QA / 진행 상황

- `docs/qa/m1-checklist.md` 수동 QA: 2·3·6·7·9·10 완료(2026-07-11). 남은 항목: 1·4·5·8.
- 세션 유지 실측 완료: 실행 중 claude 세션은 전환 왕복에도 무중단(이미 로드한 자격증명 사용).
  새 계정 적용은 세션 재시작 필요 — README '알아두면 좋은 제약'에 기록.
- needsReauth 자동 감지 배선됨(2026-07-11): usage 조회 401/403 + **저장된 expiresAt(13자리
  epoch ms, 실측)이 아직 유효할 때만** 마킹(만료 토큰 401은 오탐이라 제외), 200이면 자가 해제.
  복구는 카드 '다시 로그인' 버튼 → 기존 로그인 플로우 재사용(같은 이메일 = 토큰 갱신+해제).
  세션 로그 기반 인증 에러 감지는 실측 포맷 확보 전이라 미구현(후속).
- 후속 후보: accounts.json 파일 락, 세션 로그 기반 인증 에러 감지.
- 2차 프로젝트(합의): 멀티 PC ~/.claude 세션 동기화 — 자격증명 제외, 별도 스펙.
