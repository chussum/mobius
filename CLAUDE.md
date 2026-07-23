# Mobius (뫼비우스) — Claude·Codex 계정 매니저

Claude Code CLI + Claude Desktop + OpenAI Codex CLI 계정을 전환/자동 전환 하는
macOS 메뉴바 앱 + `mobius` CLI. Swift Package (SwiftUI, macOS 14+).
프로바이더(claude/codex)별 독립 풀 — 각 풀에서 primary 소진 → fallback 자동 전환 →
primary 회복 시 자동 복귀. 사용자 노출 용어는 '자동 전환'(구 '자동 fallback').

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
  MobiusEnvironment.swift  모든 경로 컨테이너 (MOBIUS_HOME/CODEX_HOME 오버라이드)
  Models.swift             Provider / AccountProfile / AccountsFile(프로바이더별 풀) / RateLimitInfo
  ProviderConfigIO.swift   프로바이더 어댑터 프로토콜 (secret data = 프로바이더 정의 바이트)
  KeychainClient.swift     SystemKeychain + InMemoryKeychain(테스트)
  ClaudeConfigIO.swift     Claude 자격증명 읽기/쓰기 (★ 아래 '진실의 원천' 필독)
  AccountStore.swift       프로필 영속(accounts.json) + 비밀 스냅샷(0600 파일, opaque Data)
  CodexConfigIO.swift      Codex 자격증명 읽기/쓰기 (auth.json 통째 스왑, JWT 신원)
  Switcher.swift           전환/되저장/롤백/reconcile/adopt — 등록된 어댑터 풀 전체에 적용
  RateLimitParser.swift    Claude 세션 로그 rate-limit 이벤트 파서 (실측 기반)
  CodexRateLimitParser.swift Codex rate_limits 상태 파서 (매 턴 in-band, 게이지+소진 판정)
  CodexStatusRouter.swift  Codex 상태의 계정 귀속 — 전환 전 세션 파일 격리 (오염 방지 ★아래)
  SessionLogWatcher.swift  세션 로그 tail — (루트, 파서, 정책) 주입 제네릭 (네트워크 0)
  AutoSwitchEngine.swift   순수 상태머신, 풀당 1인스턴스 (쿨다운/마진/autoSwitchedFromPrimary,
                           on/off는 풀별 autoSwitchByProvider — 기록 없는 풀은 켬; 모델스코프 pin)
  UsageFetcher.swift       Claude usage 엔드포인트 조회 (게이지용, 팝오버 열 때만; Codex는 로그로 대체)
                           모델 스코프 주간 한도(weekly_scoped)도 파싱 → ScopedUsageLimit
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
  ★ **예외(옵트인, 2026-07-21)**: Labs '한도 임박 미리 알림'(advisorySwitchEnabled) 토글을 켜면
  **활성 Claude 계정의 5시간 usage를 약 5분마다** 폴링한다(임계값 선제 알림용, 아래 QA 참조).
  **기본 꺼짐 — 끄면 폴링 0**(설정 게이트가 첫 검사라 요청 바이트 동일). 폴백 계정은 상시 폴링
  안 함(전환 후보 검증 때만, 그것도 저장 토큰 만료+쿨다운 경과 시에만 네트워크 refresh).

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
- **같은 계정 동시 refresh 금지 — checker가 합류(coalesce)로 직렬화**: 두 경로(예: 만료 임박
  스윕 vs 수동 전환 preflight)가 같은 폴백을 동시에 refresh하면 회전 때문에 늦은 쪽이 이미
  소비된 토큰으로 invalid_grant를 받아 **살아있는 계정을 needsReauth로 오마킹**한다. 진행 중
  refresh가 있으면 새로 쏘지 않고 그 결과에 합류하며, refresh 본체는 게이트 통과 후 스냅샷을
  **다시 읽는다**(직전 회전 반영 — FallbackAuthChecker.inFlight). refresh 지점을 늘리는
  변경(예: PR #2 팝오버 게이지 갱신)의 전제 조건.
- **트리거**: (1) 팝오버의 **폴백 로컬 검증**(validateFallbacksLocally) = **네트워크 0 로컬
  검사만**(빈/시간만료 refresh 토큰 즉시 플래그) — 팝오버 자체가 네트워크 0이란 뜻은 아니다((5) 예외),
  (2) **자동 폴백 전환 직전** = 실제 refresh(onTick(A)가 매 틱 재시도 → 죽은 폴백 스킵→다음 자동),
  (3) **수동 전환(계정 클릭)** = 대상 계정 refresh 1회(살았는지+신선한 토큰), (4) **만료 임박
  자동 갱신** = 폴백의 refreshTokenExpiresAt가 3일 이내면 1시간 스윕·계정당 6시간 간격으로 미리
  refresh(안 쓰던 폴백이 몇 주 뒤 조용히 죽는 것 방지), (5) **비활성 계정 usage 조회 직전** =
  저장 access 토큰이 이미 만료됐으면 refresh 후 조회(refreshUsageIfStale). 안 그러면 만료 토큰으로
  조회→429/401→조용히 스킵으로 **게이지가 마지막 스냅샷에 얼어붙어** 리셋이 안 되는 것처럼 보인다
  (실측: 비활성 계정 access 만료 후 게이지 프리즈). access TTL≈1h라 갱신 후 만료 조건이 풀려
  재-refresh는 자연히 멈춘다(스톰 없음). **★ transient(네트워크/5xx) 실패 시엔 usage 캐시가 안
  갱신돼 계속 stale로 남아 팝오버마다 회전 시도가 반복되므로, 계정당 재시도 쿨다운
  (`usageRefreshRetryCooldown` 10분)으로 백오프한다 — 성공 시 즉시 해제(만료조건 자연 소멸).**
  refresh는 access·refresh 토큰과 두 만료를 모두 갱신. → 매 팝오버 호출 없음 = 블락 위험 최소화.
### Codex (OpenAI codex CLI) — 실측 2026-07-12, codex-cli 0.144.1
- **자격증명은 `~/.codex/auth.json` 단일 파일(0600)이 유일** — Keychain 무관(승인창 이슈 없음).
  `auth_mode`/`tokens{id_token,access_token,refresh_token,account_id}`/`last_refresh`/`OPENAI_API_KEY`.
  `.codex-global-state.json`은 데스크톱 앱(Electron) UI 상태로 자격증명과 무관.
- **신원은 tokens.id_token(JWT) payload에서 로컬 추출**: `email`,
  `https://api.openai.com/auth`.chatgpt_plan_type. 서명 검증 불필요(표시용).
- ★ **auth.json은 바쁜 파일** — 실행 중인 codex 세션들이 토큰 리프레시로 수시로 다시 쓴다
  (활성 세션 7개 상태에서 갱신 실측). mtime 신호 금지 — 값 이중 읽기로 안정성 판정.
- **사용량이 세션 로그에 매 턴 in-band 포함**: `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`의
  `event_msg`/`token_count` 이벤트마다 `rate_limits{limit_id, limit_name, primary{used_percent,
  window_minutes, resets_at(epoch초)}, secondary{...}, credits, plan_type,
  rate_limit_reached_type(평시 null)}`.
  → 게이지도 네트워크 0으로 로그에서 얻는다 (Claude와 달리 usage 엔드포인트 불필요).
- ★ **창 종류는 슬롯(primary/secondary)이 아니라 `window_minutes`로 판정하라** — 슬롯 위치는
  고정이 아니다. 실측 2026-07-12: primary=5시간(300분)·secondary=주간(10080분)이었으나,
  **실측 2026-07-13: OpenAI가 5시간 한도를 임시 제거 → primary=주간(10080분)·secondary=null**.
  슬롯으로 매핑하면 주간이 "5시간" 게이지로 오표시된다(사용자 보고, 수정됨:
  CodexRateLimitStatus.shortWindow<1440분 / weeklyWindow≥1440분).
- ★ **모델 전용 한도는 `limit_name`으로 구분** — `limit_id:"codex_bengalfox",
  limit_name:"GPT-5.3-Codex-Spark"` 같은 이벤트는 특정 모델 한도라 계정 게이지·소진에서
  제외한다(계정 한도는 `limit_name==null`). Claude의 weekly_scoped(Fable)와 동일 취급 —
  안 걸러내면 계정 창과 섞여 게이지 깜빡임·오소진. (모델별 게이지 노출은 후속 후보.)
- **소진 판정은 이중화**: `rate_limit_reached_type != null`(값 형태 미실측 — 실소진 미관찰)
  **또는** `used_percent >= 100`. 리셋은 소진 창들 중 가장 늦은 resets_at.
- ★ **로그에 계정 식별자가 없다**(session_meta에도 없음, 생성 시 1회만 기록 — 실측).
  실행 중 codex 프로세스는 시작 시점 토큰을 계속 쓰므로, 전환 후에도 구 세션이 이전
  계정의 사용량(100% 포함)을 매 턴 남긴다 → 스캔 시점 활성 계정에 단순 귀속하면
  새 계정이 오염돼 연쇄 전환(B→C→D)이 난다. → `CodexStatusRouter`: 활성 변경 시점까지
  관찰된 파일은 격리(그 파일의 이후 상태 무시), 전환 후 새 파일만 현재 활성에 귀속.
  한계(보수적 선택): 전환 전 세션을 resume하면 그 파일 신호는 계속 무시되고(새 세션이
  시작되면 자연 복구), 앱 재시작 시 격리 상태는 초기화된다.
- 활성 codex 계정이 이미 한도 기록 중이면 추가 소진 상태는 처리하지 않는다 —
  매 턴 상태가 오므로 이 가드가 없으면 15초마다 알림·엔진 호출이 반복된다(알림 폭풍).
- ★ **`codex resume`는 며칠 지난 원본 rollout 파일에 이어 쓴다**(실측: 7/8 파일이 7/12 갱신).
  세션 로그가 수만 개(실측 49K, 19GB)라 Claude식 전체 프라이밍 불가 →
  SessionLogWatcher **tailOnly 정책**: 오래된 미추적 파일 무시, 처음 본 파일은 끝까지 스킵 후
  append만 파싱. **오프셋은 유지한다**(유휴 후 첫 append가 재프라이밍에 삼켜지지 않도록 —
  `testTrackedFileKeepsOffsetAcrossStaleness`가 보증; 아래 direct-stat 안전망도 이 유지에
  의존). 삭제된 파일만 추적 해제.
- ★ **날짜 파티션 프루닝 — 매 틱 전수 walk 금지**: 루트가 `YYYY/MM/DD`인데 전체(49K/19GB)를
  `FileManager.enumerator`로 훑으면 `getattrlistbulk`가 매 3초 틱마다 CPU를 태운다(실측: 유휴
  앱 CPU **19~21%**, `sample` 스택 최다 getattrlistbulk). 로그 스캔은 15초 게이트 밖이라 실제로
  매 3초 돈다 — 디렉토리가 커지며 "0.1s면 허용"이 낡았다(0.25s+, cold면 더). →
  `SessionLogWatcher.recentDirs` 주입으로 **최근 N일(Codex=7, +내일까지) 날짜 폴더만 열거**(신규
  발견) + **추적 중인 파일은 폴더 나이 무관하게 직접 확인**(옛 폴더 resume append 유지).
  **첫 스캔(프라이밍)은 프루닝 없이 전수 열거**해 창 밖 옛 폴더의 최근 파일까지 시딩한다 —
  offsets가 메모리 전용이라 재시작/오프라인 후 옛 세션 resume이 끊기지 않게(리뷰 반영, 1회
  비용). 실측: 열거 49,296→7,494개(6.6배↓), 최근 수정분 누락 0, 유휴 CPU 19%→**0.1%**,
  getattrlistbulk 3702→108. 잔여(축소된 트레이드오프): **프라이밍 이후 실행 중 처음 resume되는**
  N일+ 옛 폴더 세션만 못 봄(재시작 시 재시딩) — 계정 한도는 계정 전역이라 활성/최근 세션
  이벤트로 교차 반영된다. Claude 워처는 프로젝트별 구조라 프루닝 미적용(전체 열거 유지, 부하 작음).
- `codex login status`는 읽기 전용(해시·mtime 불변 실측), 로그인 시 exit 0 — E2E 검증 프리미티브.
- `codex login`(브라우저 OAuth)·`codex logout` 존재. `CODEX_HOME`으로 루트 오버라이드 가능.
- ★ **구 계정 세션의 리프레시가 로그인을 되돌린다(클로버)** — B 계정으로 로그인/전환해도,
  A 토큰을 메모리에 든 실행 중 세션이 토큰을 리프레시하면 auth.json을 A로 다시 쓴다
  (실측: 22:11 회사 계정 로그인 → 22:14 유휴 n 세션 리프레시가 auth.json을 n으로 되돌림).
  Mobius는 이를 외부 변경으로 보고 활성을 따라가며(라이브가 진실) 알림을 띄운다.
  전환을 안착시키려면 이전 계정의 실행 중 codex 세션을 종료해야 한다.
- ★ **스냅샷 토큰은 회전(rotation)으로 빠르게 실효될 수 있다** — 로그인 수 분 내 회전이
  일어난 뒤 클로버로 회전본이 유실되면, 스냅샷의 구 refresh token 사용 시 "refresh token
  was revoked"로 그 계정 재로그인이 필요해진다(실측). Codex 재인증 자동 감지는 미구현.
- ★ **인증 실패(401/revoked)는 rollout 로그에 안 남는다** — 웹소켓 연결 단계에서 실패해
  세션 파일 자체가 생성되지 않음(실측). 세션 로그 기반 재인증 감지는 이 에러 클래스에
  불가능 — 후속 설계는 다른 신호(전환 직후 프로브, exit code 등)가 필요.
- ★ **비활성 codex 계정 게이지는 네트워크 GET으로 얻는다(B1, CodexUsageFetcher/Prober)**:
  `GET https://chatgpt.com/backend-api/wham/usage` (헤더 `Authorization: Bearer
  <tokens.access_token>`, `ChatGPT-Account-Id: <tokens.account_id>`, 세션 UA
  `codex_cli_rs/...`를 httpAdditionalHeaders로). 응답 `rate_limit.primary_window/
  secondary_window`(used_percent/limit_window_seconds/reset_at)를 CodexRateLimitStatus로
  매핑, `additional_rate_limits[]`(limit_name 있음)은 모델 전용이라 제외. 게이지 전용 —
  refresh/마킹/엔진 호출 없음, 저장 스냅샷 읽기 전용. 활성 계정은 세션 로그 경로 유지
  (processCodexBatches 불변). Claude가 usage 엔드포인트로 비활성 계정을 보여주는 것과 대칭.
- ★ **비활성 codex 토큰 자동 갱신(게이지 전용, CodexTokenRefresher)**: `POST
  https://auth.openai.com/oauth/token`, JSON `{client_id:"app_EMoamEEZ73f0CkXaXp7hrann",
  grant_type:"refresh_token", refresh_token, scope:"openid profile email offline_access"}`,
  UA를 httpAdditionalHeaders로. client_id(=aud)·issuer(`https://auth.openai.com`, =iss)는
  codex id_token JWT 클레임에서 추출(진실의 원천). 200→토큰 **회전**(refresh_token 회전 —
  원자 저장 필수, 못 하면 brick), 401/400 `error.code=refresh_token_invalidated|
  invalid_grant`→죽음(재로그인 필요, refresh로 복구 불가). **활성 계정은 절대 refresh
  안 함**(실행 세션 클로버). 죽은 토큰은 게이지-only 방화벽(AutoSwitchEngine·persisted
  needsReauth 미접촉, 긴 쿨다운(codexRefreshDeadUntil 백오프)만). 전환↔refresh는
  `AccountStore.withCredentialLock`(UUID-keyed)이 **저장 상호배제**만 담당한다 — 전환↔회전
  HTTP 창은 락이 아니라 **AppState 게이트**(비활성 게이지 refresh 시 활성 계정 fresh-read
  제외 + 전환 진입 시 codexUsageTask 정지·완료대기)로 닫는다.

### macOS 26 (Tahoe) 환경
- 메뉴바 아이콘은 Control Center가 호스팅 — CGWindowList의 layer/owner로 존재 확인이 어려움.
- **Bartender 같은 메뉴바 관리 앱이 새 앱 아이콘을 자동 숨김** → 안 보이면 Bartender 설정에서 표시.
- 서명 안 된/ad-hoc 앱도 실행되지만 Keychain ACL이 서명 정체성에 묶임.

### 서명 (Keychain 승인창 영구 방지)
- ad-hoc 서명(`-s -`)은 **리빌드마다 정체성이 바뀌어** "항상 허용"이 매번 리셋됨.
- `Scripts/setup-signing.sh`로 고정 인증서 `Mobius Dev Signing` 생성 → make-app.sh가 자동 사용.
- 정식 인증서(Apple Developer 등)가 이미 있으면 `MOBIUS_SIGN_IDENTITY="<인증서 이름>"
  Scripts/make-app.sh`로 지정 — setup-signing.sh 불필요, 우선순위는 환경변수 > 고정 인증서 > ad-hoc.
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
15. **"계정 추가"가 앱에서만 실패, 터미널 재현은 통과하는 착시** — GUI 앱이 띄우는
    `zsh -lc`(비대화형 로그인 셸)는 `.zshrc`를 읽지 않으므로, claude의 PATH 추가가
    `.zshrc`에만 있는 환경(예: `~/.local/bin`)에선 bare `claude`가 command not found로
    즉사 → "로그인 URL을 얻지 못했습니다". 개발자 터미널 재현은 사용자 셸 PATH를
    물려받아 통과해버린다. → LoginFlow는 절대 경로로 해석해 실행(`resolveClaudeBinary`:
    표준 경로 우선 + `zsh -ilc` 대화형 폴백; 설정 표시는 `ToolInventory.locateCLI`).
    앱 조건 재현은 `env -i HOME=... PATH=/usr/bin:/bin:... /bin/zsh -lc ...`로 할 것.
16. **claude 2.1.207의 authorize URL은 별칭 — `selectAccountURL`은 경로/호스트 하드코딩으로 면역** —
    CLI가 브라우저로 여는 `claude.com/cai/oauth/authorize`는 `claude.ai/oauth/authorize`로
    307 포워딩되는 별칭이다(쿼리 보존, curl 실측). `selectAccountURL()`은 들어온 URL에서
    query만 취하고 host(`claude.ai`)·경로(`/oauth/authorize`)를 하드코딩하므로 `/cai`·
    `claude.com`을 아예 쓰지 않아 이 별칭에 면역이다 — 동적으로 경로를 읽는 구현이었다면
    `/cai` 접두사를 벗겨야 한다(안 벗기면 로그인 후 claude.ai/cai/… 404).

17. **primary 카드를 List 밖에 두면 primary 전환 시 UI가 겹쳐 깨짐 (이슈 #5)** — 계정 카드
    UI가 "고정 primary 카드 + fallback List(고정 frame)" 구조라, primary 전환이 List
    멤버십 변경(승격 행 삭제 + 강등 행 삽입)으로 diff됐다. NSTableView 기반 List는 이때
    스크롤 오프셋을 한 행 높이만큼 어긋난 채 방치 → 첫 행이 위로 잘리고 하단에 빈 공간이
    **지속**된다. 단, **전 카드 높이가 같아 frame(height:)이 안 변할 때만**(예: 전 계정
    게이지 표시, 또는 게이지 전부 꺼짐) 나타나고 높이가 바뀌면 오프셋이 재클램프되어 안
    보인다 — 개발 환경(활성만 게이지)에서 재현이 안 됐던 이유. matchedGeometryEffect,
    withAnimation은 무관(각각 제거해도 재현 — 미니 재현 앱으로 성분 분리, 2026-07-15).
    → 풀의 전 계정을 **한 List의 행**으로 두고(primary는 moveDisabled) 전환을 같은 id 집합
    내 "행 이동"으로 만들면 안 깨진다(프로바이더 풀별 List에 동일 적용 —
    AccountListView.poolCards).
    교훈: (1) 고정 frame List에서 행 삽입+삭제 조합을
    피하라 — 재정렬은 반드시 동일 데이터 집합 내 move로 모델링. (2) 안 잡히는 UI 버그는
    조건(높이 균일 여부)을 제어할 수 있는 미니 재현 앱으로 성분을 분리하면 빠르다.
    (3) UserDefaults 게이트는 `-키 값` 실행 인자(NSArgumentDomain)로 영구 설정 오염 없이
    프로세스별 오버라이드해 테스트할 수 있다.

## QA / 진행 상황

- `docs/qa/m1-checklist.md` 수동 QA: 2·3·6·7·9·10 완료(2026-07-11). 남은 항목: 1·4·5·8.
- 세션 유지 실측 완료: 실행 중 claude 세션은 전환 왕복에도 무중단(이미 로드한 자격증명 사용).
  새 계정 적용은 세션 재시작 필요 — README '알아두면 좋은 제약'에 기록.
- needsReauth 자동 감지 배선됨(2026-07-11): usage 조회 401/403 + **expiresAt(13자리
  epoch ms, 실측)이 아직 유효할 때만** 마킹(만료 토큰 401은 오탐이라 제외), 200이면 자가 해제.
  복구는 카드 '다시 로그인' 버튼 → 기존 로그인 플로우 재사용(같은 이메일 = 토큰 갱신+해제).
  세션 로그 기반 인증 에러 감지는 실측 포맷 확보 전이라 미구현(후속). **Claude 전용** —
  Codex는 재로그인 감지 경로가 아직 없다(카드 '다시 로그인'도 미노출).
  ★ **활성 계정도 자연 만료 401은 오탐이다**(이슈 #4, 2026-07-14): claude는 세션이 돌 때만
  라이브 토큰을 갱신하므로, 잠자기 등으로 한동안 안 돌면 라이브 access 토큰이 만료된 채
  남는다 → 아침 첫 팝오버 401 → 활성 오마킹 → 엔진이 needsReauth만으로 멀쩡한 주계정을
  밀어내 폴백 전환(v0.1.7부터 존재). 활성은 **refresh 토큰까지 시간 만료일 때만** 마킹
  (UsageFetcher.shouldMarkReauthAfterAuthError — claude가 못 살리는 경우만 진짜 죽음).
  단 라이브 blob에는 refreshTokenExpiresAt가 없어 이 분기는 안전망일 뿐 = 활성의 만료
  401은 사실상 절대 마킹 안 함. 진짜 폐기는 access 유효+401(즉시), 또는 비활성이 된 뒤
  폴백 refresh 기계(invalid_grant)가 잡는다 — 지연 감지를 오탐 제거와 맞바꾼 결정.
  ★ **그 지연 감지의 실제 대가가 터짐 → 연속 401 누적 신호 추가(2026-07-20)**: 활성 flosdor의
  라이브 로그인이 죽었는데(CLI가 `Login expired`) 앱은 14시간 동안 완전히 침묵했다. 실측 근거는
  usage 캐시(`usageCacheV1`)의 fetchedAt — flosdor 08:54:43 vs 같은 팝오버에서 갱신된 fore.st
  22:52:13. 즉 **매 팝오버마다 401을 받고 `catch`로 조용히 버렸고, 게이지는 마지막 성공
  스냅샷(5시간 1%)에 얼어붙어 정상처럼 보였다**(리셋 카운트다운만 실시간 계산돼 살아 보임).
  마킹이 안 된 이유: claude가 refresh에 실패하면 라이브 access가 만료된 채 남고 라이브 blob엔
  refreshTokenExpiresAt가 없어 shouldMarkReauthAfterAuthError의 두 조건이 모두 false.
  원인 규명 — accounts.json mtime(7/17)으로 **그 이후 전환 없음**, Desktop 프로필 무변동·미실행,
  활성은 모든 refresh 경로에서 제외(check 첫 guard/proactive 스윕/usage stale) → Mobius의 토큰
  회전 흔적 없음. → `AuthSuspicion` **재설계(2026-07-21, 연속-401 카운터 폐기)**: 배지는
  이제 **상태를 세지 않고** 매 평가마다 순수 재계산한다 — **Claude 세션 로그에 10분 내 활동이
  있고(SessionLogWatcher lastActivity) AND 라이브 access 토큰이 10분 넘게 만료**면 카드에 주황
  '인증 확인 필요' 배지 + '다시 로그인'. "세션은 도는데 로그인이 죽었다"를 직접 포착하므로
  (밤새/CLI 미실행이면 활동이 없어 안 뜬다), 팝오버 401을 세던 구 방식의 오탐(오프라인 몇 번)과
  과소검출을 한 번에 없앤다. 판정은 **cheap-first**: 세션 활동+캐시 만료를 먼저 값싸게 보고,
  통과할 때만 라이브값으로 confirmed 확인 — 라이브 검사는 **5분 창당 1회로 배지·임계값 폴이
  공유**(아래 5분 라이브싱크 통합; confirmed도 방금 싱크된 같은 스냅샷을 읽는 신선도 단언일 뿐
  독립 2차 읽기 아님). **영속은 알림 중복 방지용 id 셋(`authSuspectNotifiedV1`) 하나뿐** —
  판정 자체는 무상태라 재시작 후 ghost 배지가 없고, 이 셋은 "이미 알린 계정"만 기억해 재실행마다
  재알림하지 않게 쓴다(회복 시 id 제거 → 재발하면 다시 1회 알림). 구 카운터 키(`authFailuresV1`)는
  시작 시 1회 삭제. ★ **이 신호를 needsReauth로 승격 금지** —
  AutoSwitchEngine이 needsReauth를 폴백 후보 제외(:39)·주계정 강등(:93)에 쓰므로 추측성
  신호를 넣으면 이슈 #4(멀쩡한 주계정 밀어내기)가 재발한다. 표시 전용이라 오탐이 나도 전환은
  안 건드린다. 같이 고침: **stale 게이지 표시**(`AccountCardView.usageStaleAfter` 15분 —
  4분 캐시 + 10분 재시도 쿨다운을 감안한 여유값) — 기준 시각이 오래된 스냅샷은 게이지를
  50% 흐리게 + "N시간 전 값" 캡션. 실패인지 단순 미갱신인지는 **단정하지 않는다**(Codex는
  "그동안 codex를 안 썼다"는 뜻이기도 하다) — 기준 시각만 밝히고 판단은 사용자에게 맡긴다.
  ★ 얼어붙은 게이지가 특히 위험했던 이유: **초기화 카운트다운은 resets_at으로 실시간
  계산돼** 낡은 스냅샷도 살아 있는 것처럼 보인다("초기화 6일 9시간 후").
- **임계값 선제 알림/전환 (advisory) 구현됨(2026-07-21, Labs 옵트인, 기본 꺼짐)**: 활성 Claude
  계정의 5시간 usage가 임계값(기본 90, 50~95 step 5)에 도달하면 **카드에만** 노랑 '한도 근접'
  pill을 띄우고(소진 아님 — isLimited/메뉴바/CLI는 이 신호를 절대 안 본다), 여유 있는 폴백이
  있으면 자동으로 미리 전환한다. 알림 문구는 소진 표현 금지("미리 전환했어요"). ★ **진실의
  분리(Option B)**: advisory는 `AccountProfile`의 **별도 옵셔널 필드**(`AdvisoryRecord`)라
  rate-limit 레코드와 물리적으로 분리 — 소비자(카드 UI + 엔진 advisory 경로)만 읽어 소진 신호에
  절대 안 샌다. 새 전환 사유 `thresholdAdvisory`(자동 전환 플래그를 activeExhausted와 동일하게
  세움). ★ **지속 스키마에 두 필드 추가**(`advisory`, `pinnedAt`) — Models.swift의 관대한
  `init(from:)`가 `decodeIfPresent(...) ?? nil`로 구파일을 읽는다(실패 기록 13 재발 방지 —
  compat 테스트로 게이트). **읽기 실패가 아니라 쓰기 누락**은 정반대 방향으로 안전하다: **구
  바이너리가 이 파일을 저장하면 합성 인코더가 두 새 필드를 조용히 생략**하지만, 그건 그냥 advisory=nil
  로 되돌아가는 것(양성·자가치유) — 실패 기록 13은 *디코드* 실패로 계정 전체가 빈 스토어에
  덮어써진 사건이라 클래스가 다르다. ★ **비용 절감 — 5분 라이브싱크 통합**: 배지 라이브 절반과
  임계값 폴이 **같은 5분 활성-스냅샷-싱크 1회**를 공유한다(Switcher의 sync가 이제 fresh write
  여부를 Bool로 정직 반환 → 두 소비자가 Keychain 재호출 없이 로컬 스토어를 읽음). 5분 창당
  활성 계정 라이브 자격증명 subprocess는 3회가 아니라 **최대 1회**. ★ **히스테리시스 5포인트
  밴드**: set=임계값 이상, clear=임계값-5 이하 — 경계에서 사용률이 오르내려도 pill이 깜빡이거나
  알림·백오프가 매 dip마다 리셋되지 않는다. ★ **쿨다운 게이트 후보 refresh**: 폴백 후보는 저장
  토큰으로 먼저 확인(candidateProbeAction), **저장 토큰이 이미 만료 + 계정별 쿨다운 경과일 때만**
  네트워크 refresh로 에스컬레이션(기존 preflight/proactive와 같은 검증 경로 재사용) — 건강한
  폴백 토큰을 24배 빠른 주기로 회전시켜 bricking하는 것 방지. ★ **last-advised resetsAt 맵의
  읽기-전-쓰기 순서(로드-베어링)**: pollThreshold는 이 창 알림 여부(alreadyAdvised)를 맵의 **직전
  값**을 로컬로 캡처해 계산하고, 이번 폴 값은 **엔진 호출·결정 적용 이후에만** 맵에 쓴다. 쓰기를
  먼저 하면 비교가 항상 같아져 토글-off 알림이 영구히 삼켜진다(AC7). 순서: capture-local →
  compute-flag → call-engine → write-map. ★ **연속 싱크 실패 배지 = 활성 Claude 프로필 게이트**:
  refreshActiveSnapshotIfStable가 false를 반환해도 **활성 Claude 프로필이 등록돼 있을 때만** 카운터를
  올린다 — Codex-only 풀이나 adopt 대기 상태는 첫 guard에서 상시 false라, 게이트 없으면 멀쩡한
  Codex 사용자에게 매 세션 푸터 배너가 뜬다(false-positive 방지). 3회 연속 진짜 실패면 기존 5분 TTL
  푸터 배너. **AppState는 XCTest 타깃 없음** — MobiusCore 순수 함수로 결정 로직을 밀어 넣고(모델·
  엔진·스위처·배지·세션워처 테스트) 오케스트레이션은 리뷰+수동 QA로 검증.
  ★ **후속(2026-07-21, 리뷰 중 사용자 요청)**: ① **사용량 폴 서킷 브레이커** — 활성 계정
  사용량 조회가 **3연속 실패(네트워크/타임아웃/5xx)** 하면 배경 폴을 멈춘다(`UsagePollBreaker`
  순수 함수 + 테스트). 네트워크 이상 중엔 미리 전환 자체가 무의미하므로 낭비만 줄인다. 성공 시
  카운터 0, 재개는 **팝오버 열기(refreshUsageIfStale)/앱 재시작**만(인메모리, 알림 없음).
  ② **실험실 UI 문구/레이아웃 정리** — 기능명을 '미리 알림'→**'한도 차기 전 미리 전환'**(전환이
  헤드라인, 알림 아님). 상단 '자동 전환'이 꺼져 있으면 **조건부 주황 콜아웃**으로 "지금은 표시만"
  안내(콜아웃 인플레이션 방지 — 항상 띄우지 않고 문제되는 순간에만). 하위 설정(전환 기준)·동기화
  항목은 **2-depth 들여쓰기**(`SettingsView.labsIndent` 공용). ③ **실험실 전용 탭 제거** —
  설치 현황의 `settingsProviderTab`이 실험실도 공유 스코프(구 `labsProviderTab` 삭제). '꺼도
  100% 차면 평소처럼 전환'을 굵게 강조해 "끄면 자동 전환 못 받나?" 오해 방지.
- **Codex 지원 구현됨(2026-07-12, A안: 기존 개념 확장 + 프로바이더 어댑터)**:
  프로바이더별 풀(AccountsFile v2 — 구 v1 파일은 Claude 풀로 무손실 흡수, 저장은 첫 변경 때
  v2로 전환), Codex 어댑터/파서/감시, 앱 섹션 UI + CLI `--provider`, 유닛/통합 테스트 92개 green.
  계정 등록은 adopt 방식: `codex logout && codex login`하면 앱 틱이 자동 등록.
  **남은 게이트**: ① auth.json 스왑 실험(실행 중 codex 세션 없는 조용한 시점에 이동→status→복원)
  — 전환 E2E 전 필수, ② 실소진 이벤트 미관찰(rate_limit_reached_type 값 형태 — 첫 실소진 때
  fixture 확보해 파서 테스트 보강), ③ 2번째 codex 계정 등록 후 실전환 검증.
  ★ **혼합 버전 주의**: v2 accounts.json을 구버전 앱/CLI가 읽으면 활성 계정이 없어 보이고,
  구버전 UI에서 codex 프로필을 claude 경로로 전환할 수 있다(자격증명 오염 위험) —
  **새 코드로 변경(mutation)하기 전에 /Applications/Mobius.app과 CLI를 새 빌드로 교체할 것.**
- **PR #3 후속(2026-07-15)**: ① 프로바이더 키 딕셔너리(activeByProvider 등)는 **[String:]
  객체로 명시 인코딩** — Provider 키 그대로면 Swift Codable이 배열(["claude", …])로 저장한다
  (CodingKeyRepresentable 미채택, 실측). 디코딩은 관대하게: **모르는 프로바이더 키는 스킵**
  (미래 프로바이더 추가 후 다운그레이드 시 unknown raw value 하나가 파일 전체 디코드 실패
  → corrupt 백업+빈 스토어로 번지는 실패 기록 13 클래스 예방), 초기 v2의 배열 형태도 읽기
  지원(Models.decodeProviderMap). 단 per-account `provider` 필드는 여전히 unknown이면 디코드
  실패한다 — 새 프로바이더 추가 시 별도 마이그레이션 설계 필요. ② healMisassignedProviders를
  CLI makeContext에도 적용(앱과 동일 — 복구 시 stderr 경고). ③ README.en `mobius auto`
  "both if omitted" 오기 정정(미지정 시 Claude만).
- **팝오버 리디자인(2026-07-15, 사용자 피드백)**: 필 세그먼트 탭 전체/Claude/Codex —
  마지막 선택은 AppStorage `providerTab`으로 재시작 후에도 유지. 전체 탭은 풀 섹션+타이틀,
  풀 탭은 타이틀 없이 그 풀만 + 풀별 자동 전환 토글(구 헤더 토글의 귀환) + 계정 추가
  (Claude 탭=브라우저 로그인, Codex 탭=CLI 안내 팝오버, 전체 탭=선택 팝오버). 카드 시각
  위계: fallback 카드는 양쪽 8pt 들여 가운데 정렬(12pt는 수축감 커서 축소) — 행 안 스타일 변경이라 이슈 #5(List
  멤버십 불변)와 무관. ★ macOS List(NSTableView)는 행 콘텐츠에 **좌 7pt·우 9pt 자체 여백을
  비대칭으로** 얹어 카드가 List 밖 요소보다 좁고 어긋나 보인다(픽셀 실측) — 음수 패딩으로
  상쇄했고, 세로 스크롤바 거터는 `scrollDisabled(true)`로 제거(풀 List는 높이=내용이라 스크롤
  불필요). 푸터 에러 배너는 5분 TTL로 tick이 자동 소거.
  후속 다듬기(같은 날): 탭 바 100% 폭(3등분), 자동 전환 토글은 헤더 오른쪽(구 전역 토글
  자리 — 풀 탭에서만 표시, 전체 탭은 섹션 헤더의 미니 토글이 담당), 필 세그먼트는 공용
  `PillPicker`로 추출. 설정 '설치 현황'도 같은 필 탭(Claude/Codex, `settingsProviderTab`
  유지)으로 분리하고 **Desktop 동시 전환 토글 2종을 실험실 → Claude 탭으로 이동**(Claude
  전용 기능이라 제자리). mobius CLI는 설치 현황 헤더 카드(탭과 분리된 Section), 실험실도
  Claude/Codex 탭(`labsProviderTab`) — 멀티 Mac 동기화는 Claude 탭 하위(Codex 미지원 안내).
  List 높이는 행별 **런타임 실측**(rowHeights, GeometryReader)으로 잡고
  `AccountCardView.estimatedHeight`는 첫 프레임 초기값으로만 쓴다 — scrollDisabled List라
  과소추정이 잘림으로 이어지던 클래스를 제거(리뷰 반영). CLI heal은 변경 명령
  (switch/capture/auto)에서만 실행(list/status는 스킵 — 리뷰 반영).
- **설정 UI 재구성 + 자동 전환 풀별 분리(2026-07-12,
  `docs/design/settings-ui-restructure-prep.md` R1~R6 구현)**: autoSwitchEnabled(전역) →
  `autoSwitchByProvider`(풀별, 구 키는 디코드 시 양쪽 풀 적용 + encode 시 Claude 값 병행
  기록), 엔진/스토어/CLI(`mobius auto --provider`, 미지정 시 Claude=기존 동작 보존)/앱 전부 풀별 배선.
  설정 Form: 일반(언어/자동시작/게이지/mobius CLI pill 행) → 설치 현황(Claude·Codex CLI
  블록에 자동 전환 토글 + 등록 계정 요약 + 계정 추가) → 실험실(Desktop 토글 2개
  + 멀티 Mac 동기화 — 단일 experimental 섹션으로 통합) → 업데이트.
  메뉴바: 헤더 전역 토글·info popover·footer 계정 추가 제거(설정으로 일원화), ⚙/전원 히트
  타깃 28pt. 용어 '자동 fallback' → '자동 전환'(계정 역할명 primary/fallback은 유지).
  테스트 103개 green.
- **P3(monthly spend limit) 오탐 수정(2026-07-13)**: 이 이벤트는 extra usage 크레딧
  월 한도라 플랜 창이 여유여도 뜬다(실측 — 24h 폴백 기록이 멀쩡한 계정 3개를 하루 종일
  소진으로 오표시). 창 소진과 겹치면 이 메시지가 P1/P2를 가리므로(사용자 확인),
  파서는 `RateLimitHit.kind=monthlySpend`로 구분만 하고 앱이 usage로 5h/주간을 교차
  확인해 진짜 소진만 실제 리셋 시각으로 기록(`UsageSnapshot.exhaustionHit` — Codex와
  동일 의미론). 정정 기록: `docs/spike/rate-limit-format.md`.
  ★ **[정정 2026-07-14] P3 = extra-usage(크레딧) 월 지출 한도 — 표시 우선순위 override** —
  사용자 정정: 프리미엄(Fable)은 **자기 별도 한도**로 막히고, extra-usage 한도가 차면 그 메시지가
  실제 원인(Fable·다른 한도)을 **가리는 override**로 뜬다(Fable 전용 아님). 따라서 P3 문구는
  "무엇이 막혔는지"의 신뢰 신호가 아니다 → `applyVerifiedExhaustion`은 usage로 5h/주간 창을
  교차확인해 **진짜 창 소진만 기록하고 창 여유면 무시**(교차확인은 활성 계정 라이브 토큰 사용).
  프리미엄 유지 전환은 P3가 아니라 **모델 스코프 한도(usage scopedLimits/Fable) 소진**을 신뢰
  신호로 삼는 별도 후속. (앞서 'P3=프리미엄 한도'로 오판해 비핀 전환을 넣었다가 이 정정으로 되돌림.)
- ★ **Bundle.module 번들 리소스가 다른 Mac의 릴리즈 빌드에서 크래시 보고(2026-07-16, 원인
  미규명)** — v0.3.0 후원 QR(SwiftPM `.copy` 리소스 + `Bundle.module.url`)이 개발 Mac에선
  정상이었으나 타 Mac에서 버튼 클릭 시 크래시. Fairy 링크로 교체하며 리소스 로딩 자체를
  제거해 소멸. 앱에서 Bundle.module 리소스를 다시 쓰려면 **릴리즈 DMG를 다른 Mac에서 검증**
  필수 (Bundle.module 접근자는 번들을 못 찾으면 fatalError한다).
- 후속 후보: accounts.json 파일 락, 세션 로그 기반 인증 에러 감지, Codex 재로그인 감지,
  usage `limits[]`의 모델 스코프 주간 한도(weekly_scoped) 게이지 노출.
- 2차 프로젝트(합의): 멀티 PC ~/.claude 세션 동기화 — 자격증명 제외, 별도 스펙.
