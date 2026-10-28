import Foundation
import NetworkExtension

/// Управление VPN-профилем Packet Tunnel (установка, старт, стоп, статус).
final class VPNManager: ObservableObject {
    static let shared = VPNManager()
    static let extensionBundleId = "com.tgwsproxy.app.packettunnel"

    @Published var status: NEVPNStatus = .invalid
    @Published var lastError: String?

    private var manager: NETunnelProviderManager?
    private var loaded = false

    private init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(statusDidChange),
            name: .NEVPNStatusDidChange, object: nil)
    }

    func loadOrCreate() {
        guard !loaded else { return }
        loaded = true
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Загрузка профилей: \(error.localizedDescription)"
            }
            if let existing = (managers ?? []).compactMap({ $0 as? NETunnelProviderManager })
                .first(where: { ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == Self.extensionBundleId }) {
                self.manager = existing
                self.status = existing.connection.status
            } else {
                self.createManager()
            }
        }
    }

    private func createManager() {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.extensionBundleId
        proto.serverAddress = "TgWsProxy (Telegram-only)"
        proto.providerConfiguration = ["port": ProxyConst.listenPort]

        let manager = NETunnelProviderManager()
        manager.protocolConfiguration = proto
        manager.localizedDescription = "TgWsProxy"
        manager.isEnabled = true
        manager.saveToPreferences { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.lastError = "Сохранение профиля: \(error.localizedDescription)"
                return
            }
            manager.loadFromPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.lastError = "Перезагрузка профиля: \(error.localizedDescription)"
                    return
                }
                self.manager = manager
                self.status = manager.connection.status
            }
        }
    }

    func toggle() {
        guard let manager = manager else {
            loaded = false
            loadOrCreate()
            return
        }
        switch manager.connection.status {
        case .connected, .connecting, .reasserting:
            manager.connection.stopVPNTunnel()
        default:
            manager.isEnabled = true
            manager.saveToPreferences { [weak self] error in
                guard let self = self else { return }
                if let error = error {
                    self.lastError = "Включение: \(error.localizedDescription)"
                    return
                }
                manager.loadFromPreferences { [weak self] _ in
                    guard let self = self else { return }
                    do {
                        try manager.connection.startVPNTunnel()
                        self.lastError = nil
                        EventLog.shared.add("VPN: старт запрошен")
                    } catch {
                        self.lastError = "Старт VPN: \(error.localizedDescription)"
                        EventLog.shared.add("VPN: старт не удался — \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    @objc private func statusDidChange() {
        guard let manager = manager else { return }
        DispatchQueue.main.async { [weak self] in
            self?.status = manager.connection.status
        }
    }

    var statusText: String {
        switch status {
        case .connected: return "Подключён"
        case .connecting: return "Подключается…"
        case .disconnecting: return "Отключается…"
        case .disconnected: return "Отключён"
        case .invalid: return "Профиль не установлен"
        case .reasserting: return "Переподключается…"
        default: return "Неизвестно"
        }
    }
}
