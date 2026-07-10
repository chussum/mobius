# Mobius (뫼비우스)

Claude Code(CLI)를 여러 claude.ai 구독 계정으로 쓸 때, 계정 전환을 클릭 한 번/명령 한 줄로
만들어주는 macOS 메뉴바 앱 + CLI. 활성 계정의 사용 한도가 소진되면 우선순위에 따라
fallback 계정으로 자동 전환하고, primary가 리셋되면 자동 복귀한다 —
primary → fallback → primary로 끝없이 이어지는 뫼비우스 띠가 이름의 유래다.

- **지원 범위**: Claude Code CLI 계정 전환 (claude.ai OAuth 구독 계정 — 개인 Max, 회사 Team/Enterprise).
  Claude Desktop 동시 전환은 experimental로 포함.
- **제외**: Console API 키 / Bedrock / Vertex 방식 계정.
- 요구 사항: macOS 14+, `claude` CLI 설치.

## 설치

```bash
Scripts/make-app.sh      # swift build -c release + dist/Mobius.app 조립 + ad-hoc 서명
open dist/Mobius.app
```

앱은 메뉴바에만 상주한다 (Dock 아이콘 없음, 창을 닫아도 잔류).
설정에서 "로그인 시 자동 시작"을 켤 수 있다.

`mobius` CLI 설치는 둘 중 하나:

- 앱 **설정 → CLI → 설치** 버튼: 번들 내 바이너리를 `/usr/local/bin/mobius`로 심볼릭 링크 (관리자 권한 요청).
- 개발용: `Scripts/install-cli.sh` (릴리스 빌드 산출물을 직접 링크).

## 사용법

### 앱

- **계정 추가**: 팝오버의 "계정 추가" 버튼. 앱이 공식 `claude auth login`을 백그라운드로 실행해
  로그인 URL을 뽑아 **ASWebAuthenticationSession(ephemeral) 창**으로 띄운다.
  매번 쿠키가 백지 상태라 항상 로그인 폼이 뜨므로 기존 브라우저의 claude.ai 세션에
  자동 승인되지 않고, 기본 브라우저 세션도 건드리지 않는다.
  로그인 완료는 자격증명 변경 감시로 자동 감지되어 프로필로 저장되고,
  원래 쓰던 계정으로 자동 복원된다 (첫 계정이면 새 계정이 활성 유지).
  같은 계정으로 재로그인하면 신규 등록 대신 토큰 갱신으로 처리된다.
- **전환**: 계정 카드 클릭 한 번. 재로그인 불필요, 실패 시 전환 전 상태로 자동 롤백.
- **우선순위**: primary는 맨 위 고정, fallback 카드들만 드래그앤드롭으로 순서 재정렬.
  이 순서가 자동 fallback의 전환 순서다.
- **토글 3종** (설정, CLI 자동 fallback은 팝오버에도 노출):
  - `CLI 자동 fallback` (기본 켬) — 한도 소진 시 자동 전환. 끄면 알림만 오고 수동 전환은 항상 가능.
  - `Desktop 자동 fallback` (기본 끔) — 자동 전환 시 Claude Desktop도 종료→스왑→재실행.
    작업 중 Desktop이 예고 없이 재시작되는 게 싫으면 끈 채로 둔다.
  - `계정 전환 시 Claude Desktop도 전환` (experimental) — 수동 전환 시 Desktop 동시 전환.
    대상 계정에 Desktop 스냅샷이 있을 때만 동작.
- **Desktop 연결** (experimental): 계정 카드의 "Desktop 연결" → 안내 시트가 뜨고
  ① Claude Desktop이 열림 ② 해당 계정으로 로그인 ③ 로그인이 감지되면 스냅샷 자동 저장.
  이미 그 계정으로 로그인돼 있으면 "지금 상태 저장" 버튼으로 즉시 캡처.
- **메뉴바 상태 점**: primary 활성 = 기본, fallback 활성 = 앰버, 전 계정 소진 = 레드.
  자동/수동 전환마다 macOS 알림이 온다.

### CLI

```
mobius list              # 계정 목록 (활성 ●, primary/fallback 순위, 한도/재로그인 상태)
mobius switch <name>     # 닉네임으로 전환
mobius status            # 현재 활성 계정, 리셋까지 남은 시간, 자동 전환 상태
mobius capture <name>    # 현재 claude 로그인 계정을 프로필로 캡처 (앱 없이 등록하는 보조 수단)
mobius auto on|off       # CLI 자동 fallback 켜기/끄기
```

CLI 전환도 분산 알림으로 실행 중인 앱 UI에 즉시 반영된다.

## 자동 fallback 동작 원리

**네트워크 요청 0** — 서버를 조회하지 않으므로 비정상 트래픽으로 인한 계정 리스크가 없다.

1. **감지**: 15초 주기로 `~/.claude/projects/**/*.jsonl` 세션 로그의 새로 추가된 라인만 스캔한다
   (첫 스캔은 오프셋만 기록 — 과거 이벤트로 오탐하지 않음).
   `error == "rate_limit"`인 라인의 텍스트에서 리셋 시각(`resets 7:30pm (Asia/Seoul)` 등)을 파싱한다.
   단, **`not your usage limit`가 포함된 이벤트는 반드시 제외** — 실측상 rate-limit 이벤트의
   69%가 계정 한도가 아닌 서버측 제한이라, 이 규칙이 없으면 오전환이 발생한다
   (실측 기록: `docs/spike/rate-limit-format.md`).
2. **전환**: 활성 계정 소진 감지 → 우선순위 순서상 한도에 안 걸렸고 재로그인이 필요 없는
   다음 계정으로 전환. 전환할 곳이 없으면 "모든 계정 한도 소진" 알림만.
3. **복귀**: primary의 리셋 시각을 기억해두고 **타이머**로 판단 — 리셋 시각 + 마진(60초)이
   지나면 primary로 자동 복귀한다. 서버에 회복 여부를 묻지 않는다.
4. **플래핑 방지**: 전환 직후 120초 쿨다운. 전환 후에도 구 세션이 남기는 stale 로그를
   새 활성 계정의 소진으로 오인해 연쇄 전환(B→C→D)되는 것을 막는다.
5. **월간 지출 한도** 등 리셋 시각이 없는 이벤트는 보수적으로 **24시간 후 리셋**으로 취급한다.

## 제약과 알려진 한계

- **세션 유지**: 실행 중인 `claude` 세션에는 새 계정이 즉시 적용되지 않을 수 있다 —
  그 경우 세션을 새로 시작해야 한다. 실측은 미완 (QA 체크리스트 #3에서 검증 예정이며
  결과를 여기에 기록한다).
- **Claude Desktop (experimental)**:
  - 핫스왑 불가 — 전환 시 Desktop 종료→스왑→재실행이 필요하다 (Mobius가 자동화, 체감 2~5초 깜빡).
  - 웹 세션 쿠키가 만료되면(수 주) 해당 프로필은 Desktop 재로그인 후 다시 연결해야 한다.
  - 비공식 저장 구조에 의존하므로 Desktop 업데이트로 파손될 수 있다.
    파손 시 CLI 전환만 수행된다 (Desktop 전환 실패는 알림으로 고지).
- **Desktop 연결 감지**: 로그인 완료를 Desktop 데이터 디렉토리의 mtime 변경으로 감지하므로,
  로그인 외 활동(대화 등)으로도 발화할 수 있다. 안내 시트의 지시대로
  **로그인 직후 상태에서** 저장하는 것을 권장한다.
- **ad-hoc 서명**: 배포 서명이 아니라 재빌드할 때마다 앱 신원이 바뀌어
  Keychain 접근 프롬프트가 다시 뜰 수 있다.

## 보안

- Mobius가 보관하는 계정 자격증명(OAuth 토큰)은 **계정별 Keychain 항목에만** 저장된다 —
  비밀값을 파일로 내보내지 않는다 (동기화/백업 대상에서 원천 제외).
  전환 시에는 Claude Code가 원래 쓰는 위치(Keychain `Claude Code-credentials`,
  `~/.claude/.credentials.json`, `~/.claude.json`의 `oauthAccount`)에 기록할 뿐이다.
- Desktop 스냅샷은 `~/Library/Application Support/Mobius/desktop-profiles/<uuid>/`에
  **0700 권한**으로 저장된다. Cookies는 원본부터 safeStorage(Keychain 키)로 암호화되어 있어
  평문 토큰 유출이 아니며, 원본과 동일한 보호 수준이다 ("비밀값 파일 금지" 원칙의 명시적 예외).
- 계정을 삭제하면 해당 Desktop 스냅샷도 함께 삭제된다.

## QA 체크리스트

수동 통합 QA 항목: [docs/qa/m1-checklist.md](docs/qa/m1-checklist.md)
