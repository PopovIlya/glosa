import Foundation

/// JSON that keeps key order and number spelling, so editing a deck changes only the lines we touch.
/// `vocab.json` is also written by Python scripts; `pretty()` prints exactly like
/// `json.dumps(indent=2, ensure_ascii=False)`.
public indirect enum JSONValue: Equatable, Sendable {
    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) { self.key = key; self.value = value }
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSONValue? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let i = members.firstIndex(where: { $0.key == key }) {
                if let newValue { members[i].value = newValue } else { members.remove(at: i) }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var intValue: Int? { if case .number(let n) = self { return Int(n) } else { return nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }

    public static func int(_ n: Int) -> JSONValue { .number(String(n)) }

    // MARK: Printing

    public func pretty() -> String {
        var out = ""
        write(to: &out, level: 0)
        return out
    }

    private func write(to out: inout String, level: Int) {
        switch self {
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, m) in members.enumerated() {
                out += String(repeating: "  ", count: level + 1)
                JSONValue.quote(m.key, into: &out)
                out += ": "
                m.value.write(to: &out, level: level + 1)
                out += i == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: level) + "}"
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in items.enumerated() {
                out += String(repeating: "  ", count: level + 1)
                item.write(to: &out, level: level + 1)
                out += i == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: "  ", count: level) + "]"
        case .string(let s): JSONValue.quote(s, into: &out)
        case .number(let n): out += n
        case .bool(let b): out += b ? "true" : "false"
        case .null: out += "null"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }

    // MARK: Parsing

    public struct ParseError: Error, CustomStringConvertible {
        public let offset: Int
        public var description: String { "invalid JSON at byte \(offset)" }
    }

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipSpace()
        let value = try p.value()
        p.skipSpace()
        guard p.i == p.bytes.count else { throw ParseError(offset: p.i) }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[i]) { i += 1 }
        }

        mutating func expect(_ literal: String) throws {
            for b in literal.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw ParseError(offset: i) }
                i += 1
            }
        }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw ParseError(offset: i) }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var members: [Member] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skipSpace()
                    let key = try string()
                    skipSpace()
                    try expect(":")
                    skipSpace()
                    members.append(Member(key, try value()))
                    skipSpace()
                    guard i < bytes.count else { throw ParseError(offset: i) }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    try expect("}")
                    return .object(members)
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [JSONValue] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value())
                    skipSpace()
                    guard i < bytes.count else { throw ParseError(offset: i) }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    try expect("]")
                    return .array(items)
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try expect("true"); return .bool(true)
            case UInt8(ascii: "f"): try expect("false"); return .bool(false)
            case UInt8(ascii: "n"): try expect("null"); return .null
            default:
                let start = i
                while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
                guard i > start else { throw ParseError(offset: i) }
                return .number(String(decoding: bytes[start..<i], as: UTF8.self))
            }
        }

        mutating func string() throws -> String {
            try expect("\"")
            var raw: [UInt8] = []
            while i < bytes.count {
                let b = bytes[i]
                i += 1
                if b == UInt8(ascii: "\"") { return String(decoding: raw, as: UTF8.self) }
                guard b == UInt8(ascii: "\\") else { raw.append(b); continue }
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "n"): raw.append(0x0A)
                case UInt8(ascii: "r"): raw.append(0x0D)
                case UInt8(ascii: "t"): raw.append(0x09)
                case UInt8(ascii: "b"): raw.append(0x08)
                case UInt8(ascii: "f"): raw.append(0x0C)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), i + 1 < bytes.count,
                       bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    raw.append(contentsOf: Array(String(Unicode.Scalar(code) ?? "\u{FFFD}").utf8))
                default: raw.append(e) // \" \\ \/
                }
            }
            throw ParseError(offset: i)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count,
                  let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw ParseError(offset: i)
            }
            i += 4
            return v
        }
    }
}
