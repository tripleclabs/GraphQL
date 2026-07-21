@frozen
public enum FastTokenKind: UInt8, Sendable, CaseIterable {
    case eof
    case bang
    case dollar
    case ampersand
    case leftParenthesis
    case rightParenthesis
    case spread
    case colon
    case equals
    case at
    case leftBracket
    case rightBracket
    case leftBrace
    case pipe
    case rightBrace
    case name
    case integer
    case float
    case string
    case blockString
}

@frozen
public struct FastToken: Sendable, Hashable {
    public let kind: FastTokenKind
    public let range: FastSourceRange

    @inlinable
    public init(kind: FastTokenKind, start: UInt32, end: UInt32) {
        self.kind = kind
        range = FastSourceRange(start: start, end: end)
    }
}

public struct FastLexError: Error, Sendable, Equatable, CustomStringConvertible {
    public let position: UInt32
    public let reason: Reason

    public enum Reason: Sendable, Equatable {
        case sourceTooLarge
        case invalidCharacter(UInt8)
        case unexpectedCharacter(UInt8)
        case invalidNumber
        case unterminatedString
        case invalidStringCharacter(UInt8)
        case invalidEscape
    }

    public var description: String {
        "GraphQL lexical error at byte \(position): \(reason)"
    }
}

/// The Engine V2 lexer. Tokens only contain a kind and byte range; token text remains in `source`.
public enum FastLexer {
    public static func tokenize(_ source: String) throws -> ContiguousArray<FastToken> {
        if let result = try source.utf8.withContiguousStorageIfAvailable({ bytes in
            try tokenize(bytes)
        }) {
            return result
        }

        let copiedBytes = ContiguousArray(source.utf8)
        return try copiedBytes.withUnsafeBufferPointer { bytes in
            try tokenize(bytes)
        }
    }

    static func tokenize(
        _ bytes: UnsafeBufferPointer<UInt8>
    ) throws -> ContiguousArray<FastToken> {
        var scanner = try Scanner(bytes: bytes)
        return try scanner.tokenize()
    }
}

private struct Scanner {
    let bytes: UnsafeBufferPointer<UInt8>
    var position = 0
    var tokens: ContiguousArray<FastToken> = []

    init(bytes: UnsafeBufferPointer<UInt8>) throws {
        guard bytes.count <= Int(UInt32.max) else {
            throw FastLexError(position: 0, reason: .sourceTooLarge)
        }
        self.bytes = bytes
        tokens.reserveCapacity(max(8, bytes.count / 4))
    }

    mutating func tokenize() throws -> ContiguousArray<FastToken> {
        while true {
            try skipIgnored()
            let start = position
            guard position < bytes.count else {
                append(.eof, start, start)
                return tokens
            }

            let byte = bytes[position]
            switch byte {
            case 0x21: appendSingle(.bang)
            case 0x24: appendSingle(.dollar)
            case 0x26: appendSingle(.ampersand)
            case 0x28: appendSingle(.leftParenthesis)
            case 0x29: appendSingle(.rightParenthesis)
            case 0x3A: appendSingle(.colon)
            case 0x3D: appendSingle(.equals)
            case 0x40: appendSingle(.at)
            case 0x5B: appendSingle(.leftBracket)
            case 0x5D: appendSingle(.rightBracket)
            case 0x7B: appendSingle(.leftBrace)
            case 0x7C: appendSingle(.pipe)
            case 0x7D: appendSingle(.rightBrace)
            case 0x2E:
                guard position + 2 < bytes.count,
                      bytes[position + 1] == 0x2E,
                      bytes[position + 2] == 0x2E
                else {
                    throw error(.unexpectedCharacter(byte))
                }
                position += 3
                append(.spread, start, position)
            case 0x22:
                try scanString()
            case 0x2D, 0x30 ... 0x39:
                try scanNumber()
            case 0x41 ... 0x5A, 0x5F, 0x61 ... 0x7A:
                scanName()
            case 0x00 ... 0x1F:
                throw error(.invalidCharacter(byte))
            default:
                throw error(.unexpectedCharacter(byte))
            }
        }
    }

    mutating func skipIgnored() throws {
        while position < bytes.count {
            switch bytes[position] {
            case 0x09, 0x0A, 0x0D, 0x20, 0x2C:
                position += 1
            case 0x23:
                position += 1
                while position < bytes.count,
                      bytes[position] != 0x0A,
                      bytes[position] != 0x0D
                {
                    position += 1
                }
            case 0xEF where position + 2 < bytes.count &&
                bytes[position + 1] == 0xBB && bytes[position + 2] == 0xBF:
                position += 3
            case 0x00 ... 0x08, 0x0B, 0x0C, 0x0E ... 0x1F:
                throw error(.invalidCharacter(bytes[position]))
            default:
                return
            }
        }
    }

    mutating func scanName() {
        let start = position
        position += 1
        while position < bytes.count {
            switch bytes[position] {
            case 0x30 ... 0x39, 0x41 ... 0x5A, 0x5F, 0x61 ... 0x7A:
                position += 1
            default:
                append(.name, start, position)
                return
            }
        }
        append(.name, start, position)
    }

    mutating func scanNumber() throws {
        let start = position
        var kind = FastTokenKind.integer
        if bytes[position] == 0x2D {
            position += 1
            guard position < bytes.count else { throw error(.invalidNumber, at: start) }
        }

        if bytes[position] == 0x30 {
            position += 1
            if position < bytes.count, isDigit(bytes[position]) {
                throw error(.invalidNumber, at: position)
            }
        } else {
            guard isNonZeroDigit(bytes[position]) else { throw error(.invalidNumber, at: position) }
            repeat { position += 1 } while position < bytes.count && isDigit(bytes[position])
        }

        if position < bytes.count, bytes[position] == 0x2E {
            kind = .float
            position += 1
            guard position < bytes.count, isDigit(bytes[position]) else {
                throw error(.invalidNumber, at: position)
            }
            repeat { position += 1 } while position < bytes.count && isDigit(bytes[position])
        }

        if position < bytes.count, bytes[position] == 0x45 || bytes[position] == 0x65 {
            kind = .float
            position += 1
            if position < bytes.count, bytes[position] == 0x2B || bytes[position] == 0x2D {
                position += 1
            }
            guard position < bytes.count, isDigit(bytes[position]) else {
                throw error(.invalidNumber, at: position)
            }
            repeat { position += 1 } while position < bytes.count && isDigit(bytes[position])
        }

        if position < bytes.count, isNameStart(bytes[position]) {
            throw error(.invalidNumber, at: position)
        }
        append(kind, start, position)
    }

    mutating func scanString() throws {
        let start = position
        if position + 2 < bytes.count,
           bytes[position + 1] == 0x22,
           bytes[position + 2] == 0x22
        {
            position += 3
            while position + 2 < bytes.count {
                if bytes[position] == 0x22,
                   bytes[position + 1] == 0x22,
                   bytes[position + 2] == 0x22,
                   position == start + 3 || bytes[position - 1] != 0x5C
                {
                    position += 3
                    append(.blockString, start, position)
                    return
                }
                position += 1
            }
            throw error(.unterminatedString, at: start)
        }

        position += 1
        while position < bytes.count {
            let byte = bytes[position]
            if byte == 0x22 {
                position += 1
                append(.string, start, position)
                return
            }
            if byte == 0x0A || byte == 0x0D || byte < 0x20 {
                throw error(.invalidStringCharacter(byte))
            }
            if byte == 0x5C {
                position += 1
                guard position < bytes.count else { throw error(.unterminatedString, at: start) }
                switch bytes[position] {
                case 0x22, 0x2F, 0x5C, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    position += 1
                case 0x75:
                    position += 1
                    guard position + 3 < bytes.count else { throw error(.invalidEscape) }
                    for index in position ..< position + 4 where !isHex(bytes[index]) {
                        throw error(.invalidEscape, at: index)
                    }
                    position += 4
                default:
                    throw error(.invalidEscape)
                }
            } else {
                position += 1
            }
        }
        throw error(.unterminatedString, at: start)
    }

    mutating func appendSingle(_ kind: FastTokenKind) {
        let start = position
        position += 1
        append(kind, start, position)
    }

    mutating func append(_ kind: FastTokenKind, _ start: Int, _ end: Int) {
        tokens.append(FastToken(kind: kind, start: UInt32(start), end: UInt32(end)))
    }

    func error(_ reason: FastLexError.Reason, at position: Int? = nil) -> FastLexError {
        FastLexError(position: UInt32(position ?? self.position), reason: reason)
    }
}

@inline(__always)
private func isDigit(_ byte: UInt8) -> Bool {
    byte >= 0x30 && byte <= 0x39
}

@inline(__always)
private func isNonZeroDigit(_ byte: UInt8) -> Bool {
    byte >= 0x31 && byte <= 0x39
}

@inline(__always)
private func isNameStart(_ byte: UInt8) -> Bool {
    byte == 0x5F || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
}

@inline(__always)
private func isHex(_ byte: UInt8) -> Bool {
    isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
}
