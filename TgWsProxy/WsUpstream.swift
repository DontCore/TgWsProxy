import Foundation
import Network

/// WebSocket-апстрим к эндпоинту веб-клиента Telegram (kws{dc}.web.telegram.org/apiws).
/// Аналог RawWebSocket из tg-ws-proxy, но на NWProtocolWebSocket:
/// TLS и клиентское маскирование фреймов Network.framework берёт на себя.
final class WsUpstream {
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?
    var onMessage: (([UInt8]) -> Void)?
    var onClosed: (() -> Void)?

    private(set) var becameReady = false
    private var failed = false
    private let conn: NWConnection

    init(domain: String, path: String, queue: DispatchQueue) {
        let tls = NWProtocolTLS.Options()
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.subprotocols = ["binary"]
        wsOptions.autoReplyPing = true

        let params = NWParameters(tls: tls)
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        conn = NWConnection(host: NWEndpoint.Host(domain), port: NWEndpoint.Port(rawValue: ProxyConst.wsPort)!, using: params)

        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.becameReady = true
                self.onReady?()
                self.receiveNext()
            case .failed, .cancelled:
                guard !self.failed else { return }
                self.failed = true
                if self.becameReady {
                    self.onClosed?()
                } else {
                    self.onFailure?()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ data: [UInt8]) {
        guard becameReady, !failed else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "binary", metadata: [metadata])
        conn.send(content: Data(data), contentContext: context, isComplete: true,
                  completion: .contentProcessed { _ in })
    }

    func close() {
        failed = true
        conn.cancel()
    }

    private func receiveNext() {
        conn.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self, !self.failed else { return }
            if let data = content, !data.isEmpty {
                let opcode = (context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata)?.opcode
                if opcode == .close {
                    self.failed = true
                    self.onClosed?()
                    self.conn.cancel()
                    return
                }
                if opcode != .ping && opcode != .pong {
                    self.onMessage?([UInt8](data))
                }
            }
            if isComplete || error != nil {
                self.failed = true
                self.onClosed?()
                return
            }
            self.receiveNext()
        }
    }
}

/// Прямой TCP-апстрим к IP датацентра — порт _tcp_fallback.
final class TcpUpstream {
    var onReady: (() -> Void)?
    var onFailure: (() -> Void)?
    var onMessage: (([UInt8]) -> Void)?
    var onClosed: (() -> Void)?

    private(set) var becameReady = false
    private var failed = false
    private let conn: NWConnection

    init(ip: String, port: UInt16, queue: DispatchQueue) {
        conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.becameReady = true
                self.onReady?()
                self.receiveNext()
            case .failed, .cancelled:
                guard !self.failed else { return }
                self.failed = true
                if self.becameReady {
                    self.onClosed?()
                } else {
                    self.onFailure?()
                }
            default:
                break
            }
        }
        conn.start(queue: queue)
    }

    func send(_ data: [UInt8]) {
        guard becameReady, !failed else { return }
        conn.send(content: Data(data), completion: .contentProcessed { _ in })
    }

    func close() {
        failed = true
        conn.cancel()
    }

    private func receiveNext() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, isComplete, error in
            guard let self = self, !self.failed else { return }
            if let data = content, !data.isEmpty {
                self.onMessage?([UInt8](data))
            }
            if isComplete || error != nil {
                self.failed = true
                self.onClosed?()
                return
            }
            self.receiveNext()
        }
    }
}
