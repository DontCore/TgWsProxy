import Foundation
import Network

/// Локальный MTProto-прокси на 127.0.0.1:1443 с мостом в WebSocket Telegram.
/// Порт _handle_client/_run из tg_ws_proxy.py (MVP: без FakeTLS, cf_h2 и пулов).
final class ProxyServer {
    static let shared = ProxyServer()

    static let proxySecretHex: String = {
        let saved = UserDefaults.standard.string(forKey: "proxySecret")
        if let saved = saved, saved.count == 32, saved.allSatisfy({ $0.isHexDigit }) {
            return saved.lowercased()
        }
        let generated = MTProto.randomBytes(16).map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(generated, forKey: "proxySecret")
        return generated
    }()

    static var proxyLink: String {
        "tg://proxy?server=127.0.0.1&port=\(ProxyConst.listenPort)&secret=dd\(proxySecretHex)"
    }

    private(set) var isRunning = false
    private(set) var statusText = "Остановлено"
    var onStateChanged: (() -> Void)?

    private var listener: NWListener?
    private let listenerQueue = DispatchQueue(label: "tgwsproxy.listener")
    private var activeBridges: Set<ClientBridge> = []
    private var wantRunning = false
    private let stateLock = NSLock()

    private var secret: [UInt8] {
        Array(ProxyServer.proxySecretHex.hexDecodedBytes)
    }

    func start() {
        stateLock.lock()
        guard !wantRunning else { stateLock.unlock(); return }
        wantRunning = true
        stateLock.unlock()
        startListener()
    }

    func stop() {
        stateLock.lock()
        guard wantRunning else { stateLock.unlock(); return }
        wantRunning = false
        stateLock.unlock()
        listener?.cancel()
        listener = nil
        setIsRunning(false, status: "Остановлено")
    }

    private func startListener() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: ProxyConst.listenPort)!)

        guard let listener = try? NWListener(using: params) else {
            setIsRunning(false, status: "Не удалось открыть порт 1443 (занят?)")
            wantRunning = false
            return
        }
        self.listener = listener

        listener.newConnectionHandler = { [weak self] conn in
            guard let self = self else { return }
            ProxyStats.shared.connectionStarted()
            let bridge = ClientBridge(conn: conn, secret: self.secret)
            bridge.onFinished = { [weak self, weak bridge] in
                guard let self = self, let bridge = bridge else { return }
                self.activeBridges.remove(bridge)
            }
            self.activeBridges.insert(bridge)
        }

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.setIsRunning(true, status: "Работает: 127.0.0.1:\(ProxyConst.listenPort)")
            case .failed, .cancelled:
                self.setIsRunning(false, status: self.wantRunning ? "Перезапуск слушателя…" : "Остановлено")
                self.listener = nil
                if self.wantRunning {
                    self.listenerQueue.asyncAfter(deadline: .now() + 1) { [weak self] in
                        guard let self = self, self.wantRunning else { return }
                        self.startListener()
                    }
                }
            default:
                break
            }
        }

        setIsRunning(false, status: "Запуск…")
        listener.start(queue: listenerQueue)
    }

    private func setIsRunning(_ running: Bool, status: String) {
        isRunning = running
        statusText = status
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = running
            self.onStateChanged?()
        }
    }
}

/// Один клиент Telegram: handshake → (WS мост | TCP-фолбэк) → ре-шифрование.
/// Порт _handle_client, do_fallback и bridge_ws_reencrypt.
final class ClientBridge {
    var onFinished: (() -> Void)?

    private let conn: NWConnection
    private let queue: DispatchQueue
    private let secret: [UInt8]

    private var handshakeBuf: [UInt8] = []
    private var bridge: CryptoBridge?
    private var splitter: MsgSplitter?
    private var usingSplitter = false
    private var upstreamSend: (([UInt8]) -> Void)?
    private var ws: WsUpstream?
    private var tcp: TcpUpstream?
    private var finished = false
    private var timeoutWork: DispatchWorkItem?

    init(conn: NWConnection, secret: [UInt8]) {
        self.conn = conn
        self.secret = secret
        self.queue = DispatchQueue(label: "tgwsproxy.conn")
        conn.start(queue: queue)
        receiveHandshake()
    }

    // MARK: - Handshake

    private func receiveHandshake() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] content, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = content, !data.isEmpty {
                self.handshakeBuf += [UInt8](data)
            }
            if self.handshakeBuf.count >= ProxyConst.handshakeLen {
                self.handleHandshake()
                return
            }
            if isComplete || error != nil {
                self.finish()
                return
            }
            self.receiveHandshake()
        }
    }

    private func handleHandshake() {
        guard let hs = MTProto.tryHandshake(handshakeBuf, secret: secret) else {
            finish() // неверный секрет или транспорт
            return
        }

        let dcIdx = hs.isMedia ? -hs.dcId : hs.dcId
        let relayInit = MTProto.generateRelayInit(protoTag: hs.protoTag, dcIdx: dcIdx)
        guard let ctx = MTProto.buildCryptoBridge(clientPrekeyIV: hs.prekeyIV, secret: secret, relayInit: relayInit) else {
            finish()
            return
        }
        bridge = ctx
        splitter = MsgSplitter(proto: hs.protoInt)

        // WS-мост доступен только для DC из dcWsRedirect (как в оригинале)
        if ProxyConst.dcWsRedirect[hs.dcId] != nil {
            tryWsDomain(domains: ProxyConst.wsDomains(dc: hs.dcId, isMedia: hs.isMedia),
                        index: 0, path: hs.isTest ? ProxyConst.wsPathTest : ProxyConst.wsPath,
                        relayInit: relayInit)
        } else {
            tcpFallback(hs: hs, relayInit: relayInit)
        }
    }

    // MARK: - WS мост

    private func tryWsDomain(domains: [String], index: Int, path: String, relayInit: [UInt8]) {
        guard !finished else { return }
        guard index < domains.count else {
            tcpFallbackAny(dcUnknown: true, relayInit: relayInit)
            return
        }

        let upstream = WsUpstream(domain: domains[index], path: path, queue: queue)
        ws = upstream

        let timeout = DispatchWorkItem { [weak upstream] in
            guard let upstream = upstream, !upstream.becameReady else { return }
            upstream.close() // триггерит onFailure
        }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)

        upstream.onReady = { [weak self] in
            timeout.cancel()
            guard let self = self, !self.finished else { return }
            ProxyStats.shared.wsConnected()
            upstream.send(relayInit)
            self.usingSplitter = true
            self.upstreamSend = { [weak upstream] data in upstream?.send(data) }
            self.ws = upstream
            self.receiveFromClient()
            upstream.onMessage = { [weak self] data in
                self?.deliverToClient(data, fromUpstream: true)
            }
            upstream.onClosed = { [weak self] in self?.finish() }
        }
        upstream.onFailure = { [weak self] in
            timeout.cancel()
            guard let self = self, !self.finished else { return }
            self.ws = nil
            self.tryWsDomain(domains: domains, index: index + 1, path: path, relayInit: relayInit)
        }
        upstream.onClosed = { [weak self] in self?.finish() }
    }

    // MARK: - TCP фолбэк

    private func tcpFallback(hs: ClientHandshake, relayInit: [UInt8]) {
        let table = hs.isTest ? ProxyConst.dcTestIPs : ProxyConst.dcDefaultIPs
        guard let dst = table[hs.dcId] else {
            finish()
            return
        }
        openTcp(ip: dst, relayInit: relayInit)
    }

    private func tcpFallbackAny(dcUnknown: Bool, relayInit: [UInt8]) {
        openTcp(ip: ProxyConst.dcDefaultIPs[2]!, relayInit: relayInit)
        _ = dcUnknown
    }

    private func openTcp(ip: String, relayInit: [UInt8]) {
        guard !finished else { return }
        let upstream = TcpUpstream(ip: ip, port: ProxyConst.wsPort, queue: queue)
        tcp = upstream

        let timeout = DispatchWorkItem { [weak upstream] in
            guard let upstream = upstream, !upstream.becameReady else { return }
            upstream.close()
        }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)

        upstream.onReady = { [weak self] in
            timeout.cancel()
            guard let self = self, !self.finished else { return }
            ProxyStats.shared.fallbackUsed()
            upstream.send(relayInit)
            self.usingSplitter = false // потоковый бридж без нарезки, как _bridge_tcp_reencrypt
            self.upstreamSend = { [weak upstream] data in upstream?.send(data) }
            self.tcp = upstream
            self.receiveFromClient()
            upstream.onMessage = { [weak self] data in
                self?.deliverToClient(data, fromUpstream: true)
            }
            upstream.onClosed = { [weak self] in self?.finish() }
        }
        upstream.onFailure = { [weak self] in
            timeout.cancel()
            guard let self = self, !self.finished else { return }
            self.finish()
        }
        upstream.onClosed = { [weak self] in self?.finish() }
    }

    // MARK: - Бридж

    private func receiveFromClient() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] content, _, isComplete, error in
            guard let self = self, !self.finished else { return }
            if let data = content, !data.isEmpty {
                let chunk = [UInt8](data)
                ProxyStats.shared.addUp(chunk.count)
                if let ctx = self.bridge, let send = self.upstreamSend {
                    let plain = ctx.cltDec.update(chunk)
                    let reencrypted = ctx.tgEnc.update(plain)
                    if let splitter = self.splitter, self.usingSplitter {
                        for part in splitter.split(chunk: reencrypted, plain: plain) {
                            send(part)
                        }
                    } else {
                        send(reencrypted)
                    }
                }
                self.receiveFromClient()
                return
            }
            if isComplete || error != nil {
                if error == nil, let splitter = self.splitter, self.usingSplitter {
                    for tail in splitter.flush() {
                        self.upstreamSend?(tail)
                    }
                }
                self.finish()
                return
            }
            self.receiveFromClient()
        }
    }

    private func deliverToClient(_ data: [UInt8], fromUpstream: Bool) {
        guard !finished, let ctx = bridge else { return }
        ProxyStats.shared.addDown(data.count)
        let plain = ctx.tgDec.update(data)
        let out = ctx.cltEnc.update(plain)
        guard !out.isEmpty else { return }
        conn.send(content: Data(out), completion: .contentProcessed { _ in })
        _ = fromUpstream
    }

    func finish() {
        guard !finished else { return }
        finished = true
        timeoutWork?.cancel()
        ws?.close()
        tcp?.close()
        conn.cancel()
        ProxyStats.shared.connectionEnded()
        onFinished?()
    }
}

private extension String {
    /// "aabbcc…" (hex) → [0xAA, 0xBB, 0xCC, …]
    var hexDecodedBytes: [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2, limitedBy: endIndex) ?? endIndex
            if let byte = UInt8(self[index..<next], radix: 16) {
                bytes.append(byte)
            }
            index = next
        }
        return bytes
    }
}
