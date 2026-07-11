# 마일스톤 1 통합 QA 체크리스트

> 출처: `docs/superpowers/plans/2026-07-10-mobius.md` Task 14 Step 4.
> 실계정이 필요한 수동 QA 항목 — 사용자와 컨트롤러가 직접 수행 후 체크한다.
> 전제: `Scripts/make-app.sh`로 번들 생성 후 `open dist/Mobius.app` 실행 상태.

- [ ] **1. CLI 캡처/목록** — `mobius capture personal` → `mobius list`에 `● primary personal` 표시.

- [ ] **2. 계정 추가** — 앱 "계정 추가" → 인증 창에 로그인 폼(자동승인 아님) → 회사 계정 로그인 → 카드 2장, personal 활성 유지.

- [ ] **3. 카드 클릭 전환 + 세션 유지 실측** — 카드 클릭 전환 → `claude` 새 세션 시작 → `/status`에서 전환된 계정 확인. ★ 세션 유지 실측: 전환 전 실행해둔 claude 세션에서 계속 대화 시도 → 결과(무중단/재시작 필요)를 README에 기록.

- [ ] **4. CLI 전환 → 앱 반영** — `mobius switch personal` → 앱 팝오버 즉시 갱신 확인.

- [ ] **5. DnD 재정렬** — fallback 2개 이상 등록 후 드래그 재정렬 → `mobius list` 순서 반영.

- [ ] **6. 자동 전환 리허설** (실제 한도 소진 없이) — 활성 계정의 최근 세션 JSONL에 수동으로 한 줄 append:
  ```bash
  echo '{"text":"Claude AI usage limit reached|'$(date -v+2H +%s)'"}' >> ~/.claude/projects/<적당한 프로젝트>/<최근>.jsonl
  ```
  → 15초 내 fallback 전환 + 알림 확인. 이후 해당 계정 카드에 리셋 카운트다운 표시 확인.
  (테스트 후 append한 줄 제거)

- [ ] **7. 복귀 리허설** — 6번 상태에서 primary의 rateLimit을 과거로 조작: `accounts.json`의 primary `rateLimit.resetsAt`을 과거 시각으로 수정 → 다음 틱에 primary 복귀 + 알림.

- [ ] **8. 메뉴바 잔류 + 자동 시작** — 창 닫기 → 메뉴바 잔류. 설정에서 "로그인 시 자동 시작" 켜기 → 재로그인 후 자동 실행.

- [ ] **9. Keychain 권한 프롬프트 (리뷰 이월)** — 15초 주기 reconcile의 Keychain 접근이 ad-hoc 재서명 후 권한 프롬프트를 반복시키지 않는지 확인.

- [ ] **10. Desktop 업데이트 스테이징 중 전환 (ShipIt 레이스)** — Claude Desktop에 업데이트가 대기 중일 때 Desktop 전환 토글을 켜고 계정 전환 → `tail -f ~/Library/Caches/com.anthropic.claudefordesktop.ShipIt/ShipIt_stderr.log`에 `App Still Running Error`가 **안 찍히고**, 재실행된 Desktop이 키체인 승인창을 띄우지 않는지 확인. (CLAUDE.md 실패 기록 10)
