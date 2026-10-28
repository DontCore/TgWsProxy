import Foundation
import CryptoKit
import CommonCrypto

/// Стриминговый AES-CTR (CommonCrypto). Совместим с OpenSSL/cryptography:
/// IV — начальное значение 128-битного счётчика; для реальных длин сессий
/// инкремент младших 32 бит эквивалентен полному 128-битному.
final class AESCTR {
    private var cryptor: CCCryptorRef?

    init?(key: [UInt8], iv: [UInt8]) {
        guard key.count == kCCKeySizeAES256, iv.count == kCCBlockSizeAES128 else { return nil }
        var ref: CCCryptorRef?
        let status = key.withUnsafeBufferPointer { keyBuf in
            iv.withUnsafeBufferPointer { ivBuf in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                    ivBuf.baseAddress, keyBuf.baseAddress, key.count,
                    nil, 0, 0, 0, &ref)
            }
        }
        guard status == kCCSuccess, let ref = ref else { return nil }
        cryptor = ref
    }

    deinit {
        if let cryptor = cryptor { CCCryptorRelease(cryptor) }
    }

    func update(_ input: [UInt8]) -> [UInt8] {
        guard !input.isEmpty, let cryptor = cryptor else { return [] }
        var out = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = input.withUnsafeBufferPointer { inBuf in
            out.withUnsafeMutableBufferPointer { outBuf in
                CCCryptorUpdate(cryptor, inBuf.baseAddress, input.count,
                                outBuf.baseAddress, outBuf.count, &moved)
            }
        }
        guard status == kCCSuccess else { return [] }
        return Array(out.prefix(moved))
    }
}

/// Результат разбора клиентского handshake — порт _try_handshake.
struct ClientHandshake {
    let dcId: Int
    let isMedia: Bool
    let isTest: Bool
    let protoInt: UInt32
    let protoTag: [UInt8]
    let prekeyIV: [UInt8]
}

/// Четыре контекста ре-шифрования — порт CryptoCtx.
final class CryptoBridge {
    let cltDec: AESCTR // расшифровка потока клиента
    let cltEnc: AESCTR // шифрование потока клиенту
    let tgEnc: AESCTR  // шифрование потока в Telegram
    let tgDec: AESCTR  // расшифровка потока от Telegram

    init(cltDec: AESCTR, cltEnc: AESCTR, tgEnc: AESCTR, tgDec: AESCTR) {
        self.cltDec = cltDec
        self.cltEnc = cltEnc
        self.tgEnc = tgEnc
        self.tgDec = tgDec
    }
}

/// Порт протокольного ядра tg_ws_proxy.py.
enum MTProto {
    static func sha256(_ data: [UInt8]) -> [UInt8] {
        Array(SHA256.hash(data: Data(data)))
    }

    static func randomBytes(_ n: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = bytes.withUnsafeMutableBufferPointer { buf in
            SecRandomCopyBytes(kSecRandomDefault, n, buf.baseAddress!)
        }
        guard status == errSecSuccess else {
            return (0..<n).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes
    }

    /// Разбор 64-байтного обфусцированного init-пакета клиента.
    static func tryHandshake(_ handshake: [UInt8], secret: [UInt8]) -> ClientHandshake? {
        guard handshake.count == ProxyConst.handshakeLen else { return nil }
        let prekeyIV = Array(handshake[ProxyConst.skipLen..<(ProxyConst.skipLen + ProxyConst.prekeyLen + ProxyConst.ivLen)])
        let prekey = Array(prekeyIV[0..<ProxyConst.prekeyLen])
        let iv = Array(prekeyIV[ProxyConst.prekeyLen...])

        let decKey = sha256(prekey + secret)
        guard let decryptor = AESCTR(key: decKey, iv: iv) else { return nil }
        let decrypted = decryptor.update(handshake)

        let protoTag = Array(decrypted[ProxyConst.protoTagPos..<(ProxyConst.protoTagPos + 4)])
        let protoInt: UInt32
        switch protoTag {
        case ProxyConst.tagAbridged: protoInt = ProxyConst.protoAbridged
        case ProxyConst.tagIntermediate: protoInt = ProxyConst.protoIntermediate
        case ProxyConst.tagSecure: protoInt = ProxyConst.protoPadded
        default: return nil
        }

        let raw = UInt16(decrypted[ProxyConst.dcIdxPos]) | (UInt16(decrypted[ProxyConst.dcIdxPos + 1]) << 8)
        let dcIdx = Int(Int16(bitPattern: raw))

        var dc = abs(dcIdx)
        var isTest = false
        if dc >= 10000 {
            dc -= 10000
            isTest = true
        }
        return ClientHandshake(
            dcId: dc, isMedia: dcIdx < 0, isTest: isTest,
            protoInt: protoInt, protoTag: protoTag, prekeyIV: prekeyIV)
    }

    /// Генерация собственного init-пакета для апстрима — порт _generate_relay_init.
    static func generateRelayInit(protoTag: [UInt8], dcIdx: Int) -> [UInt8] {
        while true {
            let rnd = randomBytes(ProxyConst.handshakeLen)
            if ProxyConst.reservedFirstBytes.contains(rnd[0]) { continue }
            if ProxyConst.reservedStarts.contains(Array(rnd[0..<4])) { continue }
            if Array(rnd[4..<8]) == [0, 0, 0, 0] { continue }

            let key = Array(rnd[ProxyConst.skipLen..<(ProxyConst.skipLen + ProxyConst.prekeyLen)])
            let iv = Array(rnd[(ProxyConst.skipLen + ProxyConst.prekeyLen)..<(ProxyConst.skipLen + ProxyConst.prekeyLen + ProxyConst.ivLen)])
            guard let encryptor = AESCTR(key: key, iv: iv) else { continue }
            let encryptedFull = encryptor.update(rnd)

            var tailPlain = protoTag
            let dc16 = UInt16(bitPattern: Int16(truncatingIfNeeded: dcIdx))
            tailPlain.append(UInt8(dc16 & 0xFF))
            tailPlain.append(UInt8(dc16 >> 8))
            tailPlain += randomBytes(2)

            var result = rnd
            for i in 0..<8 {
                let pos = ProxyConst.protoTagPos + i
                result[pos] = tailPlain[i] ^ encryptedFull[pos] ^ rnd[pos]
            }
            return result
        }
    }

    /// Порт _build_crypto_ctx: четыре контекста из клиентского init и relay_init.
    static func buildCryptoBridge(clientPrekeyIV: [UInt8], secret: [UInt8], relayInit: [UInt8]) -> CryptoBridge? {
        // Клиент: расшифровка входящего потока (перемотка past 64-байтный init)
        let cltPrekey = Array(clientPrekeyIV[0..<ProxyConst.prekeyLen])
        let cltIv = Array(clientPrekeyIV[ProxyConst.prekeyLen...])
        guard let cltDec = AESCTR(key: sha256(cltPrekey + secret), iv: cltIv) else { return nil }
        _ = cltDec.update([UInt8](repeating: 0, count: 64))

        // Клиент: шифрование исходящего потока (реверс блока prekey+iv)
        let reversedClient = Array(clientPrekeyIV.reversed())
        let cltEncKey = sha256(Array(reversedClient[0..<ProxyConst.prekeyLen]) + secret)
        let cltEncIv = Array(reversedClient[ProxyConst.prekeyLen...])
        guard let cltEnc = AESCTR(key: cltEncKey, iv: cltEncIv) else { return nil }

        // Апстрим: шифрование (raw ключ из relay_init, без секрета), перемотка past init
        let relKey = Array(relayInit[ProxyConst.skipLen..<(ProxyConst.skipLen + ProxyConst.prekeyLen)])
        let relIv = Array(relayInit[(ProxyConst.skipLen + ProxyConst.prekeyLen)..<(ProxyConst.skipLen + ProxyConst.prekeyLen + ProxyConst.ivLen)])
        guard let tgEnc = AESCTR(key: relKey, iv: relIv) else { return nil }
        _ = tgEnc.update([UInt8](repeating: 0, count: 64))

        // Апстрим: расшифровка (реверс блока relay_init, raw ключ)
        let relDecBlock = Array(relayInit[ProxyConst.skipLen..<(ProxyConst.skipLen + ProxyConst.prekeyLen + ProxyConst.ivLen)].reversed())
        let relDecKey = Array(relDecBlock[0..<ProxyConst.keyLen])
        let relDecIv = Array(relDecBlock[ProxyConst.keyLen...])
        guard let tgDec = AESCTR(key: relDecKey, iv: relDecIv) else { return nil }

        return CryptoBridge(cltDec: cltDec, cltEnc: cltEnc, tgEnc: tgEnc, tgDec: tgDec)
    }
}
