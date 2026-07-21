public enum FastValueAccessError: Error, Sendable, Equatable {
    case indexOutOfBounds
    case expectedString
    case invalidUnicodeEscape
}

public extension FastDocument {
    /// Decodes a string literal on demand. Plain unescaped strings take a single UTF-8 slice;
    /// escaped and block strings pay their normalization cost only when validation or execution
    /// actually requests the value.
    func decodedString(valueAt index: UInt32) throws -> String {
        guard Int(index) < values.count else { throw FastValueAccessError.indexOutOfBounds }
        let value = values[Int(index)]
        guard value.kind == .string else { throw FastValueAccessError.expectedString }
        let start = Int(value.source.start)
        let end = Int(value.source.end)
        if let decoded = try source.utf8.withContiguousStorageIfAvailable({ bytes in
            try decodeStringLiteral(bytes: bytes, start: start, end: end)
        }) {
            return decoded
        }
        let bytes = ContiguousArray(source.utf8)
        return try decodeStringLiteral(bytes: bytes, start: start, end: end)
    }
}

private func decodeStringLiteral<Bytes>(
    bytes: Bytes,
    start: Int,
    end: Int
) throws -> String where Bytes: RandomAccessCollection, Bytes.Index == Int, Bytes.Element == UInt8 {
    guard start >= bytes.startIndex, start < end, end <= bytes.endIndex, bytes[start] == 0x22 else {
        throw FastValueAccessError.expectedString
    }
    if start + 2 < end, bytes[start + 1] == 0x22, bytes[start + 2] == 0x22 {
        return decodeBlockString(bytes: bytes, start: start + 3, end: end - 3)
    }
    return try decodeQuotedString(bytes: bytes, start: start + 1, end: end - 1)
}

private func decodeQuotedString<Bytes>(
    bytes: Bytes,
    start: Int,
    end: Int
) throws -> String where Bytes: RandomAccessCollection, Bytes.Index == Int, Bytes.Element == UInt8 {
    guard let firstEscape = bytes[start ..< end].firstIndex(of: 0x5C) else {
        return String(decoding: bytes[start ..< end], as: UTF8.self)
    }

    var result = String(decoding: bytes[start ..< firstEscape], as: UTF8.self)
    var position = firstEscape
    var chunkStart = position
    while position < end {
        guard bytes[position] == 0x5C else {
            position += 1
            continue
        }
        result += String(decoding: bytes[chunkStart ..< position], as: UTF8.self)
        position += 1
        switch bytes[position] {
        case 0x22: result.append("\"")
        case 0x2F: result.append("/")
        case 0x5C: result.append("\\")
        case 0x62: result.append("\u{0008}")
        case 0x66: result.append("\u{000C}")
        case 0x6E: result.append("\n")
        case 0x72: result.append("\r")
        case 0x74: result.append("\t")
        case 0x75:
            guard position + 4 < end else { throw FastValueAccessError.invalidUnicodeEscape }
            var scalar: UInt32 = 0
            for offset in 1 ... 4 {
                guard let nibble = hexValue(bytes[position + offset]) else {
                    throw FastValueAccessError.invalidUnicodeEscape
                }
                scalar = scalar << 4 | UInt32(nibble)
            }
            guard let unicode = UnicodeScalar(scalar) else {
                throw FastValueAccessError.invalidUnicodeEscape
            }
            result.unicodeScalars.append(unicode)
            position += 4
        default:
            throw FastValueAccessError.invalidUnicodeEscape
        }
        position += 1
        chunkStart = position
    }
    result += String(decoding: bytes[chunkStart ..< end], as: UTF8.self)
    return result
}

private func decodeBlockString<Bytes>(
    bytes: Bytes,
    start: Int,
    end: Int
) -> String where Bytes: RandomAccessCollection, Bytes.Index == Int, Bytes.Element == UInt8 {
    var raw: ContiguousArray<UInt8> = []
    raw.reserveCapacity(end - start)
    var position = start
    var chunkStart = start
    while position + 3 < end {
        if bytes[position] == 0x5C,
           bytes[position + 1] == 0x22,
           bytes[position + 2] == 0x22,
           bytes[position + 3] == 0x22
        {
            raw.append(contentsOf: bytes[chunkStart ..< position])
            raw.append(contentsOf: [0x22, 0x22, 0x22])
            position += 4
            chunkStart = position
        } else {
            position += 1
        }
    }
    raw.append(contentsOf: bytes[chunkStart ..< end])
    return normalizeBlockString(raw)
}

private func normalizeBlockString(_ raw: ContiguousArray<UInt8>) -> String {
    var lines = raw.split(omittingEmptySubsequences: false) { byte in
        byte == 0x0A || byte == 0x0D
    }
    var commonIndent = 0
    for index in lines.indices where index != lines.startIndex {
        let line = lines[index]
        if let firstContent = line.firstIndex(where: { $0 != 0x09 && $0 != 0x20 }) {
            let indent = line.distance(from: line.startIndex, to: firstContent)
            if commonIndent == 0 || indent < commonIndent { commonIndent = indent }
        }
    }
    if commonIndent != 0 {
        for index in lines.indices where index != lines.startIndex {
            lines[index] = lines[index].dropFirst(commonIndent)
        }
    }
    while let first = lines.first, first.allSatisfy({ $0 == 0x09 || $0 == 0x20 }) {
        lines.removeFirst()
    }
    while let last = lines.last, last.allSatisfy({ $0 == 0x09 || $0 == 0x20 }) {
        lines.removeLast()
    }
    return lines.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
}

@inline(__always)
private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30 ... 0x39: return byte - 0x30
    case 0x41 ... 0x46: return byte - 0x41 + 10
    case 0x61 ... 0x66: return byte - 0x61 + 10
    default: return nil
    }
}
