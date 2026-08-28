import Foundation

/// A minimal protobuf wire-format reader, just enough to walk GTFS-Realtime feeds.
///
/// GTFS-RT is only published as protobuf, and pulling in SwiftProtobuf plus generated sources
/// for the handful of fields this app reads (route, stop, arrival time) would be far more weight
/// than the format needs. The wire format itself is simple: a tag byte carrying a field number
/// and wire type, then a value. Unknown fields are skipped, so MTA adding extensions — and they
/// do, the NYCT extension is field 1001 — can't break parsing.
struct ProtobufReader {
    let bytes: [UInt8]
    private(set) var index: Int
    let end: Int

    init(_ data: Data) {
        bytes = [UInt8](data)
        index = 0
        end = bytes.count
    }

    init(bytes: [UInt8], range: Range<Int>) {
        self.bytes = bytes
        index = range.lowerBound
        end = range.upperBound
    }

    var hasMore: Bool { index < end }

    enum Value {
        case varint(UInt64)
        /// Range into the same backing array, so nested messages don't copy.
        case bytes(Range<Int>)
        case fixed32
        case fixed64
    }

    mutating func nextField() -> (number: Int, value: Value)? {
        guard hasMore, let key = readVarint() else { return nil }
        let number = Int(key >> 3)
        switch key & 0x07 {
        case 0:
            guard let value = readVarint() else { return nil }
            return (number, .varint(value))
        case 1:
            guard index + 8 <= end else { return nil }
            index += 8
            return (number, .fixed64)
        case 2:
            guard let length = readVarint() else { return nil }
            let start = index
            let stop = start + Int(length)
            guard stop <= end else { return nil }
            index = stop
            return (number, .bytes(start..<stop))
        case 5:
            guard index + 4 <= end else { return nil }
            index += 4
            return (number, .fixed32)
        default:
            return nil
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < end {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    func reader(for range: Range<Int>) -> ProtobufReader {
        ProtobufReader(bytes: bytes, range: range)
    }

    func string(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }
}
