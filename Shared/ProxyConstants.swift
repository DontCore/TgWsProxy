import Foundation

/// Константы протокола — порт proxy/utils.py из tg-ws-proxy.
enum ProxyConst {
    static let handshakeLen = 64
    static let skipLen = 8
    static let prekeyLen = 32
    static let keyLen = 32
    static let ivLen = 16
    static let protoTagPos = 56
    static let dcIdxPos = 60

    static let tagAbridged: [UInt8] = [0xEF, 0xEF, 0xEF, 0xEF]
    static let tagIntermediate: [UInt8] = [0xEE, 0xEE, 0xEE, 0xEE]
    static let tagSecure: [UInt8] = [0xDD, 0xDD, 0xDD, 0xDD]

    static let protoAbridged: UInt32 = 0xEFEFEFEF
    static let protoIntermediate: UInt32 = 0xEEEEEEEE
    static let protoPadded: UInt32 = 0xDDDDDDDD

    static let reservedFirstBytes: Set<UInt8> = [0xEF]
    static let reservedStarts: [[UInt8]] = [
        [0x48, 0x45, 0x41, 0x44], // HEAD
        [0x50, 0x4F, 0x53, 0x54], // POST
        [0x47, 0x45, 0x54, 0x20], // "GET "
        [0xEE, 0xEE, 0xEE, 0xEE],
        [0xDD, 0xDD, 0xDD, 0xDD],
        [0x16, 0x03, 0x01, 0x02],
        [0x4F, 0x50, 0x54, 0x49], // OPTI
    ]

    /// WS-эндпоинты доступны только для этих DC (как дефолт --dc-ip в tg-ws-proxy)
    static let dcWsRedirect: [Int: String] = [
        2: "149.154.167.220",
        4: "149.154.167.220",
    ]

    static let dcDefaultIPs: [Int: String] = [
        1: "149.154.175.50",
        2: "149.154.167.51",
        3: "149.154.175.100",
        4: "149.154.167.91",
        5: "149.154.171.5",
        203: "91.105.192.100",
    ]

    static let dcTestIPs: [Int: String] = [
        1: "149.154.175.10",
        2: "149.154.167.40",
        3: "149.154.175.117",
    ]

    static let listenPort: UInt16 = 1443
    static let wsPort: UInt16 = 443
    static let wsPath = "/apiws"
    static let wsPathTest = "/apiws_test"

    static func wsDomains(dc: Int, isMedia: Bool) -> [String] {
        let d = dc == 203 ? 2 : dc
        if !isMedia {
            return ["kws\(d).web.telegram.org"]
        }
        return ["kws\(d)-1.web.telegram.org", "kws\(d).web.telegram.org"]
    }
}
