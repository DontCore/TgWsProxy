import Foundation
import NetworkExtension

/// Packet Tunnel Provider: единственный легальный на iOS способ держать процесс
/// живым в фоне 24/7. Туннель поднимается с фиктивным маршрутом (трафик других
/// приложений не перехватывается), а внутри живёт MTProto-мост на 127.0.0.1:1443,
/// к которому Telegram подключается как к обычному MTProto-прокси.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let server = ProxyServer.shared

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        EventLog.shared.add("VPN: запуск туннеля")
        CfDomains.shared.startRefresh()

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.111.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.111.0.1"], subnetMasks: ["255.255.255.0"])
        // Фиктивный маршрут: в туннель не попадает ничей реальный трафик —
        // Telegram ходит обычной сетью в наш loopback-прокси.
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.111.222.0", subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error = error {
                EventLog.shared.add("VPN: ошибка настроек — \(error.localizedDescription)")
                completionHandler(error)
                return
            }
            self?.server.start()
            EventLog.shared.add("VPN: активен, прокси 127.0.0.1:\(ProxyConst.listenPort)")
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        EventLog.shared.add("VPN: остановка (код \(reason.rawValue))")
        server.stop()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Статистика и лог живут в SharedStore — приложению ничего пересылать не нужно.
        completionHandler?(nil)
    }
}
