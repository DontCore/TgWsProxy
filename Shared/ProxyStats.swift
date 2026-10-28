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
    private var lastFlush = Date.distantPast

    private init() {}

    private func scheduleFlush() {
        let now = Date()
        lock.lock()
        let due = now.timeIntervalSince(lastFlush) > 0.4
        if due { lastFlush = now }
        let snapshot = (connectionsTotal, connectionsActive, connectionsWs, connectionsFallback, bytesUp, bytesDown)
        lock.unlock()
        guard due else { return }
        SharedStore.defaults.set([
            "total": snapshot.0,
            "active": snapshot.1,
            "ws": snapshot.2,
            "fallback": snapshot.3,
            "up": snapshot.4,
            "down": snapshot.5,
        ], forKey: "stats")
    }

    func connectionStarted() {
        lock.lock(); connectionsTotal += 1; connectionsActive += 1; lock.unlock()
        scheduleFlush()
    }

    func connectionEnded() {
        lock.lock(); connectionsActive = max(0, connectionsActive - 1); lock.unlock()
        scheduleFlush()
    }

    func wsConnected() {
        lock.lock(); connectionsWs += 1; lock.unlock()
        scheduleFlush()
    }

    func fallbackUsed() {
        lock.lock(); connectionsFallback += 1; lock.unlock()
        scheduleFlush()
    }

    func addUp(_ n: Int) {
        lock.lock(); bytesUp += n; lock.unlock()
        scheduleFlush()
    }

    func addDown(_ n: Int) {
        lock.lock(); bytesDown += n; lock.unlock()
        scheduleFlush()
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
