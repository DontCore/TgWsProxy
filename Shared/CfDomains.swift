import Foundation

/// Список Cloudflare-проксируемых доменов для CF-фолбэка — порт balancer.py.
/// WS подключается к kws{dc}.{домен}; Cloudflare проксирует на настоящий kws{dc}.web.telegram.org.
/// Список обновляется с репозитория Flowseal (как start_cfproxy_domain_refresh).
final class CfDomains {
    static let shared = CfDomains()

    static let refreshURL = URL(string: "https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt")!

    static let defaults: [String] = [
        "virkgj.com", "vmmzovy.com", "mkuosckvso.com", "zaewayzmplad.com",
        "twdmbzcm.com", "awzwsldi.com", "clngqrflngqin.com", "tjacxbqtj.com",
        "bxaxtxmrw.com", "dmohrsgmohcrwb.com", "vwbmtmoi.com", "khgrre.com",
        "ulihssf.com", "tmhqsdqmfpmk.com", "xwuwoqbm.com", "orgcnunpj.com",
        "zhkuldz.com", "zypoljnslxa.com", "efabnxaowuzs.com", "zaftuzsftqdq.com",
    ]

    private let lock = NSLock()
    private var domains: [String]
    private var preferred: [Int: String] = [:]
    private var cooldown: [String: Date] = [:]

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: "cfDomains"), !saved.isEmpty {
            domains = saved
        } else {
            domains = Self.defaults
        }
        startRefresh()
    }

    func startRefresh() {
        URLSession.shared.dataTask(with: Self.refreshURL) { [weak self] data, _, _ in
            guard let self = self, let data = data,
                  let text = String(data: data, encoding: .utf8) else { return }
            let parsed = text.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { (1..<64).contains($0.count) && $0.allSatisfy { $0.isLetter || $0.isNumber } }
            guard !parsed.isEmpty else { return }
            self.lock.lock()
            self.domains = parsed
            self.lock.unlock()
            UserDefaults.standard.set(parsed, forKey: "cfDomains")
        }.resume()
    }

    /// Домены для DC: сначала «прижившийся», затем остальные живые, перетасованные.
    func domainsFor(dc: Int) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let d = dc == 203 ? 2 : dc
        let now = Date()
        var list = domains.filter { domain in
            if let until = cooldown[domain], until > now { return false }
            return true
        }
        list.shuffle()
        if let p = preferred[d] {
            list.removeAll { $0 == p }
            list.insert(p, at: 0)
        }
        return list
    }

    func reportSuccess(dc: Int, domain: String) {
        lock.lock()
        preferred[dc == 203 ? 2 : dc] = domain
        cooldown.removeValue(forKey: domain)
        lock.unlock()
    }

    func reportFailure(domain: String) {
        lock.lock()
        cooldown[domain] = Date().addingTimeInterval(600)
        lock.unlock()
    }
}

/// Кольцевой буфер событий для экранного лога отладки.
final class EventLog {
    static let shared = EventLog()

    private let lock = NSLock()
    private var lines: [String] = []
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ line: String) {
        let stamped = "\(Self.formatter.string(from: Date()))  \(line)"
        lock.lock()
        lines.append(stamped)
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        let snapshot = lines
        lock.unlock()
        SharedStore.defaults.set(snapshot, forKey: "eventLog")
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
