import GraphQLFast

/// Exposes the Engine V1 lexer boundary to the local Engine V2 benchmark executable without
/// making lexer implementation types part of the supported GraphQL API.
@_spi(EngineV2Benchmark)
public func engineV1TokenChecksum(_ source: String) throws -> Int {
    let lexer = createLexer(source: Source(body: source), noLocation: true)
    var checksum = 0
    while true {
        let token = try lexer.advance()
        checksum &+= token.start &* 31 &+ token.end
        if token.kind == .eof { return checksum }
    }
}

@_spi(EngineV2Benchmark)
public func engineV1FieldLookupChecksum(
    _ schema: GraphQLSchema,
    parentTypeName: String,
    fieldName: String
) throws -> Int {
    guard let parent = schema.getType(name: parentTypeName) as? GraphQLObjectType,
          let field = try parent.getFields()[fieldName]
    else { return 0 }
    return field.name.utf8.count
}

@_spi(EngineV2Benchmark)
public func engineV1PossibleTypeChecksum(
    _ schema: GraphQLSchema,
    abstractTypeName: String,
    possibleTypeName: String
) -> Int {
    guard let abstract = schema.getType(name: abstractTypeName) as? GraphQLAbstractType,
          let possible = schema.getType(name: possibleTypeName)
    else { return 0 }
    return schema.isSubType(abstractType: abstract, maybeSubType: possible) ? 1 : 0
}

@_spi(EngineV2Benchmark)
public func engineV1BenchmarkFieldDefinition(
    _ schema: GraphQLSchema,
    parentTypeName: String,
    fieldName: String
) throws -> GraphQLFieldDefinition {
    guard let parent = schema.getType(name: parentTypeName) as? GraphQLObjectType,
          let field = try parent.getFields()[fieldName]
    else {
        throw GraphQLError(message: "Benchmark field \(parentTypeName).\(fieldName) was not found.")
    }
    return field
}

@_spi(EngineV2Benchmark)
public func engineV2BenchmarkSourceResolver(
    _ schema: GraphQLSchema,
    parentTypeName: String,
    fieldName: String
) throws -> GraphQLFieldFastResolve {
    let compiled = try schema.engineV2CompiledSchema()
    guard let parent = compiled.metadata.typeID(named: parentTypeName),
          let field = compiled.metadata.fieldID(on: parent, named: fieldName),
          case let .sourceOnly(resolve) = compiled.fieldResolvers[Int(field.rawValue)]
    else {
        throw GraphQLError(
            message: "Benchmark field \(parentTypeName).\(fieldName) has no source-only resolver."
        )
    }
    return resolve
}

@inline(never)
@_spi(EngineV2Benchmark)
public func engineV1SourceResolverChecksum(
    _ field: GraphQLFieldDefinition,
    source: any Sendable
) throws -> Int {
    guard let resolve = field.fastResolve else { return 0 }
    return try resolverChecksum(resolve(source))
}

@inline(never)
@_spi(EngineV2Benchmark)
public func engineV2SourceResolverChecksum(
    _ resolve: GraphQLFieldFastResolve,
    source: any Sendable
) throws -> Int {
    try resolverChecksum(resolve(source))
}

@inline(never)
private func resolverChecksum(_ value: (any Sendable)?) -> Int {
    if let integer = value as? Int { return integer }
    return withExtendedLifetime(value) { value == nil ? 0 : 1 }
}

/// Adapts compact Engine V2 parser failures into the existing eager public error representation.
/// This is SPI while the new engine remains disconnected from the public request path.
@_spi(EngineV2Benchmark)
public func engineV2PublicParseError(
    _ error: any Error,
    source body: String
) -> GraphQLError {
    let source = Source(body: body)
    if let error = error as? FastParseError {
        return fastSyntaxError(
            source: source,
            position: Int(error.position),
            description: fastParseErrorDescription(error, source: body)
        )
    }
    if let error = error as? FastLexError {
        return fastSyntaxError(
            source: source,
            position: Int(error.position),
            description: fastLexErrorDescription(error, source: body)
        )
    }
    return GraphQLError(message: String(describing: error))
}

private func fastSyntaxError(
    source: Source,
    position: Int,
    description: String
) -> GraphQLError {
    let bytes = source.body.utf8
    let location = fastSourceLocation(source: source.body, position: position)
    let highlight = fastSourceHighlight(bytes: bytes, location: location)
    let message = "Syntax Error \(source.name) (\(location.line):\(location.column)) " +
        description + "\n\n" + highlight
    return GraphQLError(
        syntaxMessage: message,
        source: source,
        position: position,
        location: location
    )
}

private func fastSourceLocation(
    source: String,
    position: Int
) -> SourceLocation {
    var line = 1
    var column = position + 1
    var offset = 0
    var index = source.utf16.startIndex
    while index != source.utf16.endIndex {
        let codeUnit = source.utf16[index]
        source.utf16.formIndex(after: &index)
        let newlineStart = offset
        offset += 1
        if codeUnit == 0x000D {
            if index != source.utf16.endIndex, source.utf16[index] == 0x000A {
                source.utf16.formIndex(after: &index)
                offset += 1
            }
        } else if codeUnit != 0x000A {
            continue
        }
        if newlineStart < position {
            line += 1
            column = position + 1 - offset
        }
    }
    return SourceLocation(line: line, column: column)
}

private func fastSourceHighlight<Bytes>(
    bytes: Bytes,
    location: SourceLocation
) -> String where Bytes: Collection, Bytes.Element == UInt8 {
    var ranges: [Range<Bytes.Index>] = []
    ranges.reserveCapacity(3)
    var line = 1
    var lineStart = bytes.startIndex
    var index = bytes.startIndex

    while index != bytes.endIndex, line <= location.line + 1 {
        let byte = bytes[index]
        if byte == 0x0A || byte == 0x0D {
            if line >= location.line - 1 { ranges.append(lineStart ..< index) }
            bytes.formIndex(after: &index)
            if byte == 0x0D, index != bytes.endIndex, bytes[index] == 0x0A {
                bytes.formIndex(after: &index)
            }
            line += 1
            lineStart = index
        } else {
            bytes.formIndex(after: &index)
        }
    }
    if line <= location.line + 1, line >= location.line - 1 {
        ranges.append(lineStart ..< bytes.endIndex)
    }

    let firstLineNumber = max(location.line - 1, 1)
    let padLength = String(location.line + 1).count
    var result = ""
    for (offset, range) in ranges.enumerated() {
        let lineNumber = firstLineNumber + offset
        result += fastLeftPad(padLength, String(lineNumber)) + ": " +
            String(decoding: bytes[range], as: UTF8.self) + "\n"
        if lineNumber == location.line {
            result += String(repeating: " ", count: max(2 + padLength + location.column, 0)) + "^\n"
        }
    }
    return result
}

private func fastLeftPad(_ length: Int, _ string: String) -> String {
    String(repeating: " ", count: max(length - string.count + 1, 0)) + string
}

private func fastParseErrorDescription(_ error: FastParseError, source: String) -> String {
    let found = fastTokenDescription(error.found, source: source)
    switch error.reason {
    case let .expected(kind):
        return "Expected \(fastTokenKindDescription(kind)), found \(found)"
    case let .expectedKeyword(keyword):
        return "Expected \"\(keyword)\", found \(found)"
    case .expectedName:
        return "Expected Name, found \(found)"
    case .expectedValue, .unexpected:
        return "Unexpected \(found)"
    case .unsupported:
        return "Unexpected \(found)"
    }
}

private func fastLexErrorDescription(_ error: FastLexError, source: String) -> String {
    switch error.reason {
    case .sourceTooLarge:
        return "Source is too large."
    case let .invalidCharacter(byte):
        return "Invalid character \(Character(UnicodeScalar(byte)))."
    case let .unexpectedCharacter(byte):
        return "Unexpected character \(Character(UnicodeScalar(byte)))."
    case let .invalidNumberExpectedDigit(byte):
        let found = byte.map { String(Character(UnicodeScalar($0))) } ?? "<EOF>"
        return "Invalid number, expected digit but got: \(found)."
    case let .invalidNumberUnexpectedDigitAfterZero(byte):
        return "Invalid number, unexpected digit after 0: \(Character(UnicodeScalar(byte)))."
    case .unterminatedString:
        return "Unterminated string."
    case .unterminatedBlockString:
        return "Unterminated blockstring"
    case let .invalidStringCharacter(byte):
        return "Invalid character within String: \(Character(UnicodeScalar(byte)))."
    case let .invalidBlockStringCharacter(byte):
        return "Invalid character within BlockString: \(Character(UnicodeScalar(byte)))."
    case let .invalidEscape(range):
        let bytes = source.utf8
        let start = bytes.index(bytes.startIndex, offsetBy: Int(range.start))
        let end = bytes.index(bytes.startIndex, offsetBy: Int(range.end))
        return "Invalid character escape sequence: \(String(decoding: bytes[start ..< end], as: UTF8.self))."
    case let .invalidUnicodeEscape(range):
        let bytes = source.utf8
        guard range.end - range.start >= 6 else {
            let start = bytes.index(bytes.startIndex, offsetBy: Int(range.start))
            let end = bytes.index(bytes.startIndex, offsetBy: Int(range.end))
            return "Invalid character escape sequence: \(String(decoding: bytes[start ..< end], as: UTF8.self))."
        }
        let start = bytes.index(bytes.startIndex, offsetBy: Int(range.start) + 2)
        let end = bytes.index(bytes.startIndex, offsetBy: Int(range.end) - 1)
        return "Invalid character escape sequence: \\u\(bytes[start ... end])."
    }
}

private func fastTokenDescription(_ token: FastToken, source: String) -> String {
    switch token.kind {
    case .eof:
        return "<EOF>"
    case .name, .integer, .float, .string, .blockString:
        let start = source.utf8.index(source.utf8.startIndex, offsetBy: Int(token.range.start))
        let end = source.utf8.index(source.utf8.startIndex, offsetBy: Int(token.range.end))
        return "\(fastTokenKindDescription(token.kind)) \"\(String(decoding: source.utf8[start ..< end], as: UTF8.self))\""
    default:
        return fastTokenKindDescription(token.kind)
    }
}

private func fastTokenKindDescription(_ kind: FastTokenKind) -> String {
    switch kind {
    case .eof: return "<EOF>"
    case .bang: return "!"
    case .dollar: return "$"
    case .ampersand: return "&"
    case .leftParenthesis: return "("
    case .rightParenthesis: return ")"
    case .spread: return "..."
    case .colon: return ":"
    case .equals: return "="
    case .at: return "@"
    case .leftBracket: return "["
    case .rightBracket: return "]"
    case .leftBrace: return "{"
    case .pipe: return "|"
    case .rightBrace: return "}"
    case .name: return "Name"
    case .integer: return "Int"
    case .float: return "Float"
    case .string: return "String"
    case .blockString: return "BlockString"
    }
}
