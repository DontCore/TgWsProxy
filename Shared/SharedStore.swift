import Foundation

/// Общее хранилище состояние (приложение ↔ Packet Tunnel extension) через App Group.
/// Если App Group не доступна при подписи — тихий фолбэк на локальные UserDefaults
/// (extension тогда не сможет делиться статистикой с приложением, но работать будет).
enum SharedStore {
    static let suiteName = "group.com.tgwsproxy.app"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}
