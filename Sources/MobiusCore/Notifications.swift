import Foundation

public enum MobiusNotification {
    /// 계정 목록/활성 상태 변경 시 앱·CLI 상호 통지
    public static let accountsChanged = Notification.Name("com.mobius.accountsChanged")

    public static func postAccountsChanged() {
        DistributedNotificationCenter.default()
            .postNotificationName(accountsChanged, object: nil, userInfo: nil,
                                  deliverImmediately: true)
    }
}
