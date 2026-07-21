import Foundation

/// 변경 전(advisory/pinnedAt 도입 이전) accounts.json 픽스처 — 실제 사용자 파일의 현행
/// 스키마(실측 2026-07-20)를 그대로 옮기고 두 신규 키만 없는 상태다. 이메일/닉네임 등은
/// 대체값이지만 **키 구성과 형태는 실물과 동일**해야 의미가 있다 (직접 만든 최소 JSON은
/// 실제 파일에만 있는 키를 놓쳐 하위호환 검증을 헛돌게 한다).
///
/// 이 픽스처가 디코드되지 않으면 실패 기록 13이 그대로 재현된다 — 빈 스토어 폴백 →
/// 다음 save가 원본 덮어쓰기 → 계정 영구 유실.
let preAdvisoryAccountsFileFixture = """
{
 "accounts": [
  {
   "id": "1197AFFD-F75E-4920-AF28-F311D4C80CF8",
   "provider": "claude",
   "nickname": "personal",
   "emailAddress": "p@example.com",
   "organizationName": "P Org",
   "tierDescription": "Max 20X",
   "needsReauth": false,
   "hasDesktopSnapshot": true,
   "userPinned": true,
   "rateLimit": {
    "recordedAt": 805974090.194353,
    "resetsAt": 805975199.9909999,
    "modelScoped": false
   }
  },
  {
   "id": "193895B2-9D50-4D39-8552-6D3F49588E90",
   "provider": "codex",
   "nickname": "codex-plus",
   "emailAddress": "c@example.com",
   "organizationName": "C Org",
   "tierDescription": "Plus",
   "needsReauth": false,
   "hasDesktopSnapshot": false,
   "userPinned": false
  }
 ],
 "activeByProvider": {
  "claude": "1197AFFD-F75E-4920-AF28-F311D4C80CF8",
  "codex": "193895B2-9D50-4D39-8552-6D3F49588E90"
 },
 "autoSwitchedByProvider": {"claude": false},
 "autoSwitchByProvider": {"claude": false, "codex": false},
 "desktopSyncEnabled": true,
 "desktopAutoSwitchEnabled": false,
 "activeAccountID": "1197AFFD-F75E-4920-AF28-F311D4C80CF8",
 "autoSwitchEnabled": false,
 "autoSwitchedFromPrimary": false
}
"""

/// 픽스처의 rateLimit 리셋 전 시각 — Date 기본 디코딩이 timeIntervalSinceReferenceDate라
/// 픽스처의 숫자와 같은 기준으로 만든다.
let fixtureNow = Date(timeIntervalSinceReferenceDate: 805_974_100)
