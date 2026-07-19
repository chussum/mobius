# Mobius

**한국어** | [English](README.en.md)

**Claude·Codex 계정, 이제 갈아탈 필요 없이 이어 쓰세요.**

Claude나 Codex를 여러 구독 계정으로 쓰고 계신가요? 한도가 다 차면 로그아웃하고, 다른 계정으로
로그인하고, 리셋되면 다시 돌아오고… Mobius는 이 반복을 없애줍니다.

- **클릭 한 번으로 계정 전환** — 재로그인 없이 즉시 바뀝니다.
- **한도가 차면 자동으로 다음 계정으로** — 작업 흐름이 끊기지 않습니다.
- **한도가 풀리면 원래 계정으로 자동 복귀** — 신경 쓸 필요가 없습니다.

primary → fallback → 다시 primary. 끝없이 이어지는 뫼비우스 띠처럼, 이름도 여기서 왔습니다.

<p align="center">
  <img src="docs/images/screenshot.png" width="440" alt="Mobius 메뉴바 팝오버 — 프로바이더 탭(전체·Claude·Codex), 계정 카드, 사용량 게이지">
</p>

메뉴바의 ∞ 아이콘을 누르면 위 화면이 열립니다. 상단 **전체 / Claude / Codex 탭**으로
프로바이더를 골라 볼 수 있고, 계정마다 **5시간/주간 사용량 게이지**와
**리셋까지 남은 시간**이 보이며, 카드를 누르면 그 계정으로 바로 전환됩니다.

## 이런 분께 맞습니다

- Claude Max 개인 계정 + 회사 계정을 오가며 쓰는 분
- 한도 소진 알림을 보고 나서야 계정을 바꾸던 분
- 터미널(Claude Code CLI)과 Claude Desktop 앱을 함께 쓰는 분

> **지원**: claude.ai 구독 계정(개인 Max, 회사 Team/Enterprise)의 Claude Code CLI 전환,
> OpenAI **Codex CLI**(ChatGPT 구독 로그인) 전환 — 두 프로바이더는 독립 풀로 각각
> 자동 전환·복귀합니다. Claude Desktop 동시 전환은 실험 기능으로 포함.
> **미지원**: Console/OpenAI API 키 / Bedrock / Vertex 방식.
> **요구 사항**: macOS 14 이상 + 전환하려는 프로바이더의 CLI(`claude` / `codex`).

> [!IMPORTANT]
> **개인 계정은 1개 사용을 권장합니다.** 회사 ↔ 개인처럼 성격이 다른 계정을
> 오가는 것이 Mobius의 의도된 사용법입니다. 한도를 늘릴 목적으로 개인 계정을
> 2개 이상 돌려 쓰는 것은 각 서비스 약관에 어긋날 수 있으며, 이로 인해 계정이
> 제한·차단되더라도 Mobius는 책임지지 않습니다.

## 설치

### 1. 다운로드

[**Releases 페이지**](https://github.com/chussum/claude-mobius/releases/latest)에서
최신 버전의 `Mobius-x.y.z.dmg`를 받으세요.

### 2. 설치

받은 DMG를 열고 **Mobius를 Applications 폴더로 드래그**하면 끝입니다.

### 3. 처음 열기

Applications의 **Mobius를 더블클릭**하면 바로 실행됩니다. 릴리스 버전은 Apple의
**Developer ID 서명 + 공증(notarization)** 을 거치므로 "확인되지 않은 개발자" 경고 없이 열립니다.

<details>
<summary>소스에서 직접 빌드한 경우 경고가 뜬다면</summary>

<br>

공증되지 않은 자체빌드(자체서명/ad-hoc)는 처음 실행할 때 *"'Mobius'은(는) 확인되지 않은
개발자가 배포했기 때문에 열 수 없습니다"* 경고가 뜰 수 있습니다. **최초 1회만** 앱을
**우클릭 → 열기**, 또는 **시스템 설정 → 개인정보 보호 및 보안**에서 **"그래도 열기"** 를 눌러주세요.

<p align="center">
  <img src="docs/images/gatekeeper-ko.png" width="440" alt="시스템 설정 → 개인정보 보호 및 보안 — 차단 안내 옆의 '그래도 열기' 버튼">
</p>
</details>

실행되면 Dock이 아니라 **메뉴바에 ∞ 아이콘**으로 상주합니다. 창을 닫아도 계속 지켜보고
있으니 안심하세요. 설정에서 "로그인 시 자동 시작"을 켜두면 더 편합니다.

> **개발자라면**: 소스에서 직접 빌드할 수 있습니다 —
> `Scripts/make-app.sh && open dist/Mobius.app`
> (고정 서명 인증서는 최초 1회 `Scripts/setup-signing.sh`).
> 터미널용 `mobius` CLI는 앱 **설정 → 설치 현황 → Mobius CLI → 설치** 버튼 또는 `Scripts/install-cli.sh`.
> 릴리스 서명·공증·배포는 [docs/RELEASING.md](docs/RELEASING.md) 참고.

## 시작하기

1. 메뉴바 ∞ 아이콘 → 하단 **계정 추가**
2. 로그인 창이 뜨면 추가할 Claude 계정으로 로그인 — 끝!
   (Codex는 터미널에서 `codex login` 한 번이면 몇 초 안에 자동 등록됩니다.)

로그인 창은 매번 깨끗한 상태로 열리므로 브라우저에 남아 있던 claude.ai 세션에
자동 승인되는 일이 없고, 쓰던 브라우저 세션도 건드리지 않습니다.
로그인이 끝나면 자동으로 감지해 계정을 등록하고, 원래 쓰던 계정으로 되돌려 둡니다.
같은 계정으로 다시 로그인하면 중복 등록 대신 토큰만 갱신됩니다.

### 일상 사용

- **전환**: 계정 카드를 클릭. 재로그인 없이 즉시 바뀌고, 실패하면 전환 전 상태로 자동 롤백됩니다.
- **우선순위 정하기**: 맨 위가 primary(기본 계정), 아래가 fallback입니다.
  fallback 카드는 드래그로 순서를 바꿀 수 있고, 이 순서대로 자동 전환됩니다.
  fallback을 primary로 올리려면 카드 **우클릭(또는 ⋯ 메뉴) → "Primary 계정으로 설정"**.
- **메뉴바 아이콘 색**: 기본(primary 사용 중) · 앰버(fallback 사용 중) · 레드(모든 계정 소진).
  전환이 일어날 때마다 macOS 알림으로 알려줍니다.

### 설정 토글

**자동 전환**(CLI별)은 팝오버에서 바로 켜고 끌 수 있고(Claude/Codex 탭의 헤더,
전체 탭에서는 섹션 라벨 오른쪽), 설정(⚙) → 설치 현황의 각 프로바이더 탭에도 있습니다.
Claude Desktop 토글 2개는 **설치 현황 → Claude 탭**의 Claude Desktop 아래에 있습니다.

| 토글 | 위치 | 기본값 | 하는 일 |
|---|---|---|---|
| 자동 전환 (CLI별) | 팝오버 · 설치 현황 각 탭 | 켬 | 한도가 차면 다음 계정으로 자동 전환. 끄면 알림만 오고 수동 전환은 언제나 가능 |
| 자동 전환 시에도 Claude Desktop 전환 | 설치 현황 · Claude 탭 | 끔 | 자동 전환 때 Claude Desktop도 함께 전환 (전환 순간 Desktop이 재시작됨) |
| 계정 전환 시 Claude Desktop도 전환 | 설치 현황 · Claude 탭 | 끔 | 카드 클릭 전환 때 Desktop 동시 전환. 해당 계정을 Desktop에 연결해둔 경우에만 동작 |

### Claude Desktop도 함께 쓰려면

계정 카드의 **⋯ → "Claude Desktop 연결"**을 누르면 안내에 따라
① Desktop이 열리고 ② 그 계정으로 로그인하면 ③ 자동으로 저장됩니다.
연결해두면 계정 전환 시 Desktop도 같은 계정으로 따라 바뀝니다 (재시작 2~5초).

### 여러 Mac에서 이어 쓰기 (실험실)

**설정 → 실험실 → 다른 Mac과 동기화**를 켜면 iCloud Drive·Google Drive(또는 직접 선택한
폴더)를 통해 대화 기록·플랜·스킬·글로벌 메모리(CLAUDE.md)·플러그인 목록을 여러 Mac이
공유합니다. 어느 Mac에서든 대화를 이어 하고, Claude가 배운 내용도 함께 씁니다.

- **로그인 정보는 옮기지 않습니다** — 계정 자격증명·계정 목록·비밀 토큰은 어떤 경우에도
  동기화되지 않습니다 (코드 수준에서 차단, 테스트로 보증).
- 이 Mac에서 켠 항목만 참여합니다. 꺼둔 Mac은 아무 영향도 받지 않습니다.
- 삭제 처리는 선택: "다른 Mac에는 남겨두기(기본)" 또는 "다른 Mac에서도 지우기"
  (즉시 삭제 대신 휴지통 폴더에 30일 보관).
- 홈 폴더 안 프로젝트는 Mac마다 사용자명이 달라도 대화를 이어 쓸 수 있습니다
  (동기화 시 홈 경로를 자동 치환). 홈 밖 경로는 두 Mac의 경로가 같아야 합니다.

## 터미널에서도 쓸 수 있어요 (선택)

앱만으로 모든 기능을 쓸 수 있지만, 터미널이 익숙하다면 `mobius` 명령으로도 전환할 수 있습니다
(앱 **설정 → 설치 현황 → Mobius CLI → 설치**):

```
mobius list                        # 계정 목록 — 프로바이더별 섹션 (활성 ●, 우선순위, 한도 상태)
mobius switch <name>               # 닉네임으로 전환 (중복 닉네임은 --provider claude|codex)
mobius status                      # 프로바이더별 현재 활성 계정, 리셋까지 남은 시간
mobius capture <name>              # 현재 claude 로그인 계정을 프로필로 등록
mobius capture <name> --provider codex   # 현재 codex 로그인 계정을 등록
mobius auto on|off                 # 자동 전환 켜기/끄기 (--provider claude|codex, 미지정 시 Claude)
```

CLI로 전환해도 실행 중인 앱 화면에 즉시 반영됩니다.
단, Desktop 동시 전환은 앱에서 전환할 때만 적용됩니다 — `mobius switch`는 CLI 자격증명만 바꿉니다.

## 자동 전환은 어떻게 동작하나요

**한도 감지는 네트워크를 전혀 쓰지 않습니다** — 로컬 세션 로그만 읽으므로 비정상 트래픽으로
계정이 위험해질 일이 없습니다. Mobius가 서버를 호출하는 건 사용량 게이지(팝오버 열 때만,
4분 캐시), 로그인, 그리고 하루 한 번의 업데이트 확인(GitHub, 설정에서 끄기 가능)뿐이며,
게이지와 업데이트 확인을 끄면 백그라운드 네트워크 사용은 0입니다.

1. **감지**: 15초마다 세션 로그의 새 라인만 스캔합니다 (첫 스캔은 오프셋만 기록 — 과거 이벤트
   오탐 없음). Claude는 `~/.claude/projects/**/*.jsonl`의 rate-limit 이벤트에서 리셋 시각을
   파싱하되 `not your usage limit` 포함 이벤트를 제외합니다 — 실측상 rate-limit 이벤트의 69%가
   계정 한도가 아닌 서버측 제한이라, 이 규칙이 없으면 오전환이 발생합니다
   (실측 기록: `docs/spike/rate-limit-format.md`). Codex는 `~/.codex/sessions/**/*.jsonl`에
   매 턴 실리는 구조화된 사용량(rate_limits)을 읽습니다 — 사용량 게이지도 여기서 얻어
   Codex는 서버 조회가 아예 없습니다.
2. **전환**: 활성 계정 소진 → 우선순위상 한도에 안 걸린 다음 계정으로.
   갈 곳이 없으면 "모든 계정 한도 소진" 알림만 보냅니다.
3. **복귀**: primary의 리셋 시각 + 60초가 지나면 타이머로 자동 복귀합니다. 서버 조회 없음.
4. **플래핑 방지**: 전환 직후 120초 쿨다운 — 구 세션의 잔여 로그 때문에 연쇄 전환(B→C→D)되는 것을 막습니다.
5. 리셋 시각이 없는 이벤트(월간 지출 한도 등)는 보수적으로 24시간 후 리셋으로 취급합니다.

사용량 게이지는 팝오버를 열 때만 조회하며(4분 캐시), 상시 폴링하지 않습니다.

## 알아두면 좋은 제약

- **Codex 계정 추가**: 터미널에서 `codex logout` 후 `codex login`으로 추가할 계정에
  로그인하면 Mobius가 몇 초 안에 자동 등록합니다 (지금 쓰던 계정은 이미 카드에 저장돼 있어
  카드를 눌러 되돌아올 수 있습니다). Codex의 "재로그인 필요" 자동 감지는 아직 없습니다.
- **Codex 전환이 되돌아간다면**: 이전 계정으로 실행 중인 codex 세션이 토큰을 갱신하면서
  로그인을 자기 계정으로 되돌릴 수 있습니다 (Mobius가 알림으로 알려줍니다).
  전환을 유지하려면 이전 계정의 실행 중 codex 세션을 종료하세요.
- **실행 중인 `claude` 세션**: 전환해도 기존 세션은 **끊기지 않고 계속 동작합니다**
  (수동/자동 전환 왕복을 여러 차례 겪어도 무중단 — 2026-07-11 실측).
  다만 이미 실행 중인 세션은 이전 계정의 자격증명을 계속 쓰므로,
  새 계정을 적용하려면 세션을 새로 시작하세요.
- **재로그인 필요 자동 감지**: 토큰이 폐기된 계정은 자동으로 감지되어(기존 사용량 조회 재활용 —
  추가 요청 없음) 카드에 **"다시 로그인" 버튼**이 나타납니다. 자동 전환은 해당 계정을 건너뜁니다.
- **전환 직후 일시적 오표시**: 구 세션의 잔여 로그로 새 계정 카드에 리셋 카운트다운이
  잠깐 잘못 보일 수 있습니다 (시간이 지나면 자연 해소).
- **Claude Desktop**:
  - 핫스왑이 불가능해 전환 시 Desktop 재시작이 필요합니다 (자동화되어 있고 2~5초 깜빡임).
  - 웹 세션 쿠키가 만료되면(수 주) 해당 계정은 Desktop 재로그인 후 다시 연결해야 합니다.
  - 비공식 저장 구조에 의존하므로 Desktop 업데이트로 동작이 깨질 수 있습니다.
    깨져도 CLI 전환은 정상 동작하며, Desktop 전환 실패는 알림으로 알려줍니다.
- **키체인 확인 창이 뜬다면**: 과거 버전 사용 등으로 키체인 항목의 파티션이 오염된 경우입니다.
  터미널에서 한 번만 실행하면 됩니다 (키체인 암호 필요):
  ```bash
  security set-generic-password-partition-list -S "apple-tool:,apple:" -s "Claude Code-credentials" -a $USER
  ```
  이후에는 Mobius가 호환 상태를 자동으로 유지합니다.

## 보안

- **비밀값은 어디에도 업로드되지 않습니다.** 계정별 OAuth 토큰 스냅샷은
  `~/Library/Application Support/Mobius/secrets/`에 **본인만 읽을 수 있는 권한(0600)**으로
  저장됩니다 — Claude Code 자신이 토큰을 보관하는 방식과 동일한 보호 수준입니다.
- 전환 시에는 Claude Code가 원래 쓰는 위치(Keychain `Claude Code-credentials`,
  `~/.claude/.credentials.json`, `~/.claude.json`의 `oauthAccount`)에 기록할 뿐입니다.
  키체인 읽기/쓰기는 macOS 표준 `security` 도구를 경유해 claude 생태계와 충돌하지 않습니다.
- Desktop 스냅샷은 `~/Library/Application Support/Mobius/desktop-profiles/`에 0700 권한으로
  저장됩니다. Cookies는 원본부터 Keychain 키로 암호화되어 있어 평문 유출이 아닙니다.
- 계정을 삭제하면 해당 비밀 스냅샷과 Desktop 스냅샷도 함께 삭제됩니다.

## 함께 만든 사람들

이슈 제보, 리뷰, PR로 Mobius를 함께 만들어주신 분들입니다 🙏

[![Contributors](https://contrib.rocks/image?repo=chussum/mobius)](https://github.com/chussum/mobius/graphs/contributors)

## 라이센스

MIT 라이센스로 배포됩니다 — 전문은 [`LICENSE`](LICENSE)를 참고하세요.

유일한 외부 의존성인 [swift-argument-parser](https://github.com/apple/swift-argument-parser)(Apple, Apache License 2.0)의 고지는 [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)에 있습니다.

> 이 프로젝트는 오픈소스 개인 프로젝트이며 **Anthropic·OpenAI 어느 쪽과도 무관합니다.**
> "Claude"와 "Anthropic"은 Anthropic PBC의, "Codex"와 "ChatGPT"는 OpenAI의 상표이며,
> 여기서는 호환 대상 제품을 가리키기 위한 서술적 용도로만 사용됩니다.
