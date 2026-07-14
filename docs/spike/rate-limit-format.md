# 스파이크: rate-limit 이벤트 포맷 실측

- 실측일: 2026-07-10
- 대상: `~/.claude/projects/**/*.jsonl` (1,153개 파일, 약 817MB)
- 목적: Task 7 `RateLimitParser`가 파싱해야 할 실제 rate-limit 이벤트 포맷 확정

## 0. 스캔 방법 메모

플랜의 Step 1 grep 명령은 이 머신에서 **빈 결과**를 반환했다. 원인: 이 머신의 `grep`이
`ugrep` 셸 함수로 셰이딩되어 있고, `.{0,80}(…).{0,120}` 형태의 regex가
`ugrep: error: … exceeds complexity limits`로 조용히 실패(stderr는 `2>/dev/null`로 삼켜짐).
→ `rg`(ripgrep)로 재스캔하여 실측 성공. **Task 7/8 구현 시 셸 grep에 의존하지 말 것**
(어차피 Swift 파서는 자체 정규식 사용).

## 1. 실측 결과 — 실제 rate-limit 이벤트가 존재함

`"error":"rate_limit"` 항목이 41개 파일에서 총 59건 발견됨 (2026-06 ~ 2026-07-09,
CLI v2.1.181 ~ v2.1.205). 이벤트는 **한 줄짜리 JSON 객체**로, 일반 assistant 메시지와
같은 골격에 에러 필드가 추가된 형태다.

### 1.1 이벤트 라인의 실제 구조 (민감값 마스킹)

```json
{
  "parentUuid": "xxxxxxxx-…",
  "isSidechain": false,
  "type": "assistant",
  "uuid": "xxxxxxxx-…",
  "timestamp": "2026-06-19T08:48:23.930Z",
  "message": {
    "id": "xxxxxxxx-…",
    "model": "<synthetic>",
    "role": "assistant",
    "type": "message",
    "usage": { "input_tokens": 0, "output_tokens": 0, "…": "…" },
    "content": [
      { "type": "text", "text": "You've hit your session limit · resets 7:30pm (Asia/Seoul)" }
    ]
  },
  "requestId": "req_xxxxxxxxxxxxxxxxxxxxxxxx",
  "error": "rate_limit",
  "isApiErrorMessage": true,
  "apiErrorStatus": 429,
  "userType": "external",
  "entrypoint": "cli",
  "cwd": "/…(마스킹)…",
  "sessionId": "xxxxxxxx-…",
  "version": "2.1.181",
  "gitBranch": "…",
  "slug": "…"
}
```

핵심 판별 필드 (구조화 필드로 판별 가능 — 텍스트 grep보다 안전):

| 필드 | 값 | 의미 |
|---|---|---|
| `type` | `"assistant"` | 이벤트가 assistant 메시지로 기록됨 |
| `error` | `"rate_limit"` | **1차 판별 키**. 그 외 관측값: `authentication_failed`, `server_error`, `unknown`, `invalid_request` |
| `isApiErrorMessage` | `true` | API 에러 메시지 여부 |
| `apiErrorStatus` | `429` | HTTP 상태. 계정 한도는 전부 429. (일부 구버전 항목엔 이 필드 없음) |
| `message.model` | `"<synthetic>"` | 실제 모델 응답이 아닌 합성 메시지 |
| `message.content[0].text` | 아래 §1.2 | **리셋 시각은 이 텍스트 안에만 있음** |

### 1.2 관측된 텍스트 변형 전체 (59건 중복 제거)

| 건수 | `apiErrorStatus` | 텍스트 | 리셋 시각 | 계정 전환 트리거? |
|---|---|---|---|---|
| 41 | 429 | `API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited` | 없음 | **아니오** — 서버측 제한, 계정 한도 아님 |
| 8 | 429 | `You've hit your monthly spend limit · raise it at claude.ai/settings/usage` | 없음 | 예 (리셋 시각 없음 — 폴백만) |
| 5 | 429 | `You've hit your session limit · resets 7:30pm (Asia/Seoul)` (4건) / `… resets 2:30pm (Asia/Seoul)` (1건) | 텍스트 (당일 시각 + TZ) | **예** |
| 4 | 429 | `You've hit your weekly limit · resets Jul 13 at 8am (Asia/Seoul)` | 텍스트 (날짜 + 시각 + TZ) | **예** |
| 1 | (없음) | `Claude <모델명> is currently unavailable. Learn more: …` | 없음 | 아니오 — 모델 가용성 이슈 |

리셋 시각 표기 패턴 (실측):

- 세션 한도: `resets 7:30pm (Asia/Seoul)`, `resets 2:30pm (Asia/Seoul)` — `resets <h[:mm]><am|pm> (<IANA TZ>)`. 당일(또는 익일) 시각.
- 주간 한도: `resets Jul 13 at 8am (Asia/Seoul)` — `resets <Mon D> at <h[:mm]><am|pm> (<IANA TZ>)`.
- 분 단위가 0이면 `:00` 생략 (`8am`), 아니면 포함 (`7:30pm`).
- 타임존은 IANA 이름이 괄호로 붙음 → epoch 계산 시 이 TZ 기준으로 해석해야 함.

### 1.3 후보 패턴 2종(플랜)의 실측 여부

1. `Claude AI usage limit reached|<unix-epoch>` — **실제 이벤트로는 미발견.**
   `~/.claude/projects` 전체에서 이 패턴이 나온 파일은 Mobius 플랜 문서를 다룬 세션 로그뿐
   (자기참조). 구버전 CLI의 포맷으로 추정되며, 이 머신의 로그(v2.1.x)에는 현행 포맷만 남음.
2. `…usage limit reached…resets at <시각>` — 문자 그대로는 미발견. 현행 표현은
   `You've hit your <session|weekly> limit · resets <시각>` (`resets at`이 아니라 `resets`,
   단 주간 한도는 `resets Jul 13 at 8am`처럼 날짜 뒤에 `at`이 옴).

## 2. 참고 — JSONL 일반 라인 구조

한 줄 = JSON 객체 하나. `type` 필드로 구분되며 관측된 값:
`assistant`, `user`, `system`, `attachment`, `mode`, `file-history-snapshot`
(+ 서브에이전트 로그는 `<session>/subagents/agent-*.jsonl`에 동일 포맷).

- `type:"user"` / `type:"assistant"`: `message.role`, `message.content`(블록 배열: `text`, `tool_use`, `tool_result` 등), `timestamp`(ISO8601 UTC), `sessionId`, `cwd`, `version` 등.
- `type:"file-history-snapshot"`, `type:"mode"` 등 메타 라인에는 `timestamp`가 없을 수 있음.
- 라인이 매우 길 수 있음(수백 KB) → 파서는 라인 단위 스트리밍 + JSON 디코드 실패 라인 스킵.

## 3. 결론 — Task 7 RateLimitParser가 커버해야 할 패턴

판별 알고리즘 (권장):

1. 라인을 JSON으로 디코드. 실패 시 스킵.
2. `error == "rate_limit"` (또는 방어적으로 `isApiErrorMessage == true && apiErrorStatus == 429`) 인 라인만 후보.
3. `message.content[].text`를 이어붙여 아래 텍스트 패턴으로 분류:

| # | 패턴 (정규식 스케치) | 분류 | 리셋 시각 |
|---|---|---|---|
| P1 | `You've hit your session limit · resets (\d{1,2}(?::\d{2})?)(am\|pm) \(([^)]+)\)` | 세션 한도 → 전환 | 당일/익일 해당 시각, TZ는 캡처된 IANA명 |
| P2 | `You've hit your weekly limit · resets ([A-Z][a-z]{2} \d{1,2}) at (\d{1,2}(?::\d{2})?)(am\|pm) \(([^)]+)\)` | 주간 한도 → 전환 | 날짜+시각, TZ 동일 |
| P3 | `You've hit your monthly spend limit` | ~~지출 한도 → 전환~~ **[정정 2026-07-13]** 소진 기록 금지 — usage 교차 확인으로 대체 (아래 주의사항) | 없음 |
| P4 | `usage limit reached\|(\d{10,13})` | 레거시 epoch 포맷 (미실측, 하위호환 유지) | epoch 그대로 |
| P5 | `(usage\|session\|weekly) limit.*resets? (at )?(.+)` | 미래 변형 대비 관대한 폴백 | best-effort 파싱 |
| — | `not your usage limit` 포함 시 | **제외** (서버측 rate limit) | — |

주의사항:

- **[정정 2026-07-13] P3(monthly spend limit)는 창 소진이 아니다** — 이 이벤트는
  extra usage 크레딧의 월 한도로, **플랜 5h/주간 창이 여유여도 뜨고 세션은 계속
  동작한다**(실측: 00:13~00:14 KST에 실행 중 세션 15개 파일에 동시 기록, 이후에도
  해당 계정 세션 정상 동작 — 24h 폴백으로 기록했더니 멀쩡한 계정 3개가 하루 종일
  '소진'으로 오표시). 단 창 소진과 겹치면 **이 메시지가 우선 표시돼 P1/P2를 가린다**
  (사용자 확인) → 파서는 kind=monthlySpend로 구분만 하고, 앱이 usage 엔드포인트로
  5h/주간 현황을 교차 확인해 진짜 소진이면 실제 리셋 시각으로 기록한다.
- **[정정 2026-07-14] P3("monthly spend limit") = extra-usage(크레딧) 월 지출 한도이며 표시
  우선순위 override** — 사용자 정정: 프리미엄(Fable)은 **자기 별도 한도**로 막히고, extra-usage
  한도가 다 차면 그 메시지가 실제 원인(Fable·다른 한도)을 **가리는 override**로 뜬다(Fable
  전용이 아니라 어느 한도든 동일). 그래서 P3 문구만으론 "무엇이 막혔는지" 알 수 없다.
  → `applyVerifiedExhaustion`은 usage로 5h/주간 창을 교차확인해 **진짜 창 소진만 기록하고 창
  여유면 무시**(2026-07-13 원래 동작 유지). 교차확인은 활성 계정 라이브 토큰 사용(만료 스냅샷
  회피). 프리미엄 유지 전환은 P3가 아니라 **모델 스코프 한도(usage scopedLimits/Fable) 소진**을
  신뢰 신호로 삼는 별도 후속으로 설계한다. (앞서 'P3=프리미엄 한도'로 오판해 비핀 전환을 넣었다가 되돌림.)
- **`not your usage limit` 제외 규칙이 가장 중요** — 실측 59건 중 41건(69%)이 서버측 제한이라 이걸 계정 한도로 오인하면 불필요한 전환이 발생한다.
- 리셋 시각 텍스트는 이벤트의 `(IANA TZ)` 기준으로 해석. "당일 vs 익일"은 이벤트 `timestamp`와 비교해 이미 지난 시각이면 익일로 굴림.
- 텍스트 문구는 CLI 버전에 따라 변할 수 있음(v2.1.181→205 사이에도 표현 다양). 구조화 필드(`error`, `apiErrorStatus`) 우선 + 텍스트는 리셋 시각 추출용으로만 쓰는 이중 구조가 안전.
