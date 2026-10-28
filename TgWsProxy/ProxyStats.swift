import Foundation

final class ProxyStats {
    static let shared = ProxyStats()

    private let lock = NSLock()
    private(set) var connectionsTotal = 0
    private(set) var connectionsActive = 0
    private(set) var connectionsWs = 0
    private(set) var connectionsFallback = 0
    private(set) var bytesUp = 0
    private(set) var bytesDown = 0

    private init() {}

    func connectionStarted() {
        lock.lock(); connectionsTotal += 1; connectionsActive += 1; lock.unlock()
    }

    func connectionEnded() {
        lock.lock(); connectionsActive = max(0, connectionsActive - 1); lock.unlock()
    }

    func wsConnected() {
        lock.lock(); connectionsWs += 1; lock.unlock()
    }

    func fallbackUsed() {
        lock.lock(); connectionsFallback += 1; lock.unlock()
    }

    func addUp(_ n: Int) {
        lock.lock(); bytesUp += n; lock.unlock()
    }

    func addDown(_ n: Int) {
        lock.lock(); bytesDown += n; lock.unlock()
    }

    func humanBytes(_ n: Int) -> String {
        var value = Double(n)
        for unit in ["Б", "КБ", "МБ", "ГБ"] {
            if abs(value) < 1024 {
                return String(format: "%.1f%@", value, unit)
            }
            value /= 1024
        }
        return String(format: "%.1fТБ", value)
    }
}
