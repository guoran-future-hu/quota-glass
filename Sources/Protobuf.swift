// GetGrokCreditsConfig 走 gRPC-web，响应是没有 schema 的 protobuf。
// 只解到够用：varint / fixed32 / length-delimited，fixed64 跳过。

import Foundation

enum Wire {
    case varint(UInt64)
    case fixed32(UInt32)
    case bytes(Data)
}

struct Proto {
    var fields: [Int: [Wire]] = [:]

    init(_ data: Data) {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            var shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        while index < bytes.count, let key = varint() {
            let field = Int(key >> 3)
            guard field > 0 else { return }
            switch key & 7 {
            case 0:
                guard let value = varint() else { return }
                fields[field, default: []].append(.varint(value))
            case 1:
                guard index + 8 <= bytes.count else { return }
                index += 8
            case 2:
                guard let length = varint().map(Int.init), length < 8_000_000, index + length <= bytes.count else { return }
                fields[field, default: []].append(.bytes(Data(bytes[index..<(index + length)])))
                index += length
            case 5:
                guard index + 4 <= bytes.count else { return }
                let bits = (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * $1) }
                fields[field, default: []].append(.fixed32(bits))
                index += 4
            default:
                return
            }
        }
    }

    func varint(_ field: Int) -> UInt64? {
        if case .varint(let value) = fields[field]?.first { return value }
        return nil
    }

    func float(_ field: Int) -> Double? {
        switch fields[field]?.first {
        case .fixed32(let bits):
            let value = Double(Float(bitPattern: bits))
            return value.isFinite ? value : nil
        case .varint(let value) where value <= 10_000:
            return Double(value)
        default:
            return nil
        }
    }

    func string(_ field: Int) -> String? {
        guard case .bytes(let data) = fields[field]?.first else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func message(_ field: Int) -> Proto? { messages(field).first }

    func messages(_ field: Int) -> [Proto] {
        (fields[field] ?? []).compactMap { if case .bytes(let data) = $0 { Proto(data) } else { nil } }
    }

    /// google.protobuf.Timestamp：field 1 是秒。
    func timestamp(_ field: Int) -> Date? {
        message(field)?.varint(1).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

/// 拆 gRPC-web 帧（1 字节 flag + 4 字节长度）；不像帧就整段当一条消息。trailer 帧（flag 0x80）丢掉。
func grpcPayloads(_ data: Data) -> [Data] {
    let bytes = [UInt8](data)
    guard let flag = bytes.first, [0x00, 0x01, 0x80].contains(flag) else { return [data] }
    var index = 0
    var payloads: [Data] = []
    while index + 5 <= bytes.count {
        let flag = bytes[index]
        let length = bytes[(index + 1)...(index + 4)].reduce(0) { $0 << 8 | Int($1) }
        index += 5
        guard index + length <= bytes.count else { break }
        if flag & 0x80 == 0, length > 0 { payloads.append(Data(bytes[index..<(index + length)])) }
        index += length
    }
    return payloads.isEmpty ? [data] : payloads
}
