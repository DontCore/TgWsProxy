import Foundation

/// Порт MsgSplitter из bridge.py: нарезает пере-шифрованный поток на
/// MTProto-транспортные пакеты (каждый отправляется отдельным WS-фреймом).
/// Длины читаются из открытого текста, нарезаются — шифротекст.
final class MsgSplitter {
    private let proto: UInt32
    private var cipherBuf: [UInt8] = []
    private var plainBuf: [UInt8] = []
    private var disabled = false

    init?(proto: UInt32) {
        guard proto == ProxyConst.protoAbridged
                || proto == ProxyConst.protoIntermediate
                || proto == ProxyConst.protoPadded else { return nil }
        self.proto = proto
    }

    func split(chunk: [UInt8], plain: [UInt8]) -> [[UInt8]] {
        if chunk.isEmpty { return [] }
        if disabled { return [chunk] }

        cipherBuf += chunk
        plainBuf += plain

        var parts: [[UInt8]] = []
        var offset = 0
        let bufLen = cipherBuf.count
        while offset < bufLen {
            guard let packetLen = nextPacketLen(offset: offset, avail: bufLen - offset) else { break }
            if packetLen <= 0 {
                parts.append(offset == 0 ? cipherBuf : Array(cipherBuf[offset...]))
                offset = bufLen
                disabled = true
                break
            }
            if offset == 0 && packetLen == bufLen {
                parts.append(cipherBuf)
            } else {
                parts.append(Array(cipherBuf[offset..<min(offset + packetLen, bufLen)]))
            }
            offset += packetLen
        }

        if offset > 0 {
            cipherBuf.removeFirst(offset)
            plainBuf.removeFirst(offset)
        }
        return parts
    }

    func flush() -> [[UInt8]] {
        if cipherBuf.isEmpty { return [] }
        let tail = cipherBuf
        cipherBuf.removeAll()
        plainBuf.removeAll()
        return [tail]
    }

    private func nextPacketLen(offset: Int, avail: Int) -> Int? {
        if avail <= 0 { return nil }
        if proto == ProxyConst.protoAbridged { return nextAbridgedLen(offset: offset, avail: avail) }
        if proto == ProxyConst.protoIntermediate || proto == ProxyConst.protoPadded {
            return nextIntermediateLen(offset: offset, avail: avail)
        }
        return 0
    }

    private func nextAbridgedLen(offset: Int, avail: Int) -> Int? {
        let first = plainBuf[offset]
        let payloadLen: Int
        let headerLen: Int
        if first == 0x7F || first == 0xFF {
            if avail < 4 { return nil }
            let b0 = UInt32(plainBuf[offset + 1])
            let b1 = UInt32(plainBuf[offset + 2])
            let b2 = UInt32(plainBuf[offset + 3])
            payloadLen = Int(b0 | (b1 << 8) | (b2 << 16)) * 4
            headerLen = 4
        } else {
            payloadLen = Int(first & 0x7F) * 4
            headerLen = 1
        }
        if payloadLen <= 0 { return 0 }
        let packetLen = headerLen + payloadLen
        if avail < packetLen { return nil }
        return packetLen
    }

    private func nextIntermediateLen(offset: Int, avail: Int) -> Int? {
        if avail < 4 { return nil }
        let l0 = UInt32(plainBuf[offset])
        let l1 = UInt32(plainBuf[offset + 1])
        let l2 = UInt32(plainBuf[offset + 2])
        let l3 = UInt32(plainBuf[offset + 3])
        let payloadLen = Int((l0 | (l1 << 8) | (l2 << 16) | (l3 << 24)) & 0x7FFF_FFFF)
        if payloadLen <= 0 { return 0 }
        let packetLen = 4 + payloadLen
        if avail < packetLen { return nil }
        return packetLen
    }
}
