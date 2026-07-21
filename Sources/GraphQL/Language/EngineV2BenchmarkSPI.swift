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

/// Adapts compact Engine V2 parser failures into the existing eager public error representation.
/// This is SPI while the new engine remains disconnected from the public request path.
@_spi(EngineV2Benchmark)
public func engineV2PublicParseError(
    _ error: any Error,
    source body: String
) -> GraphQLError {
    let source = Source(body: body)
    if let error = error as? FastParseError {
        return syntaxError(
            source: source,
            position: Int(error.position),
            description: fastParseErrorDescription(error, source: body)
        )
    }
    if let error = error as? FastLexError {
        return syntaxError(
            source: source,
            position: Int(error.position),
            description: fastLexErrorDescription(error)
        )
    }
    return GraphQLError(message: String(describing: error))
}

private func fastParseErrorDescription(_ error: FastParseError, source: String) -> String {
    let found = fastTokenDescription(error.found, source: source)
    switch error.reason {
    case let .expected(kind):
        return "Expected \(fastTokenKindDescription(kind)), found \(found)"
    case .expectedName:
        return "Expected Name, found \(found)"
    case .expectedValue:
        return "Unexpected \(found)"
    case .unsupported:
        return "Unexpected \(found)"
    }
}

private func fastLexErrorDescription(_ error: FastLexError) -> String {
    switch error.reason {
    case .sourceTooLarge:
        return "Source is too large."
    case let .invalidCharacter(byte):
        return "Invalid character \(Character(UnicodeScalar(byte)))."
    case let .unexpectedCharacter(byte):
        return "Unexpected character \"\(Character(UnicodeScalar(byte)))\"."
    case .invalidNumber:
        return "Invalid number."
    case .unterminatedString:
        return "Unterminated string."
    case let .invalidStringCharacter(byte):
        return "Invalid character within String: \(Character(UnicodeScalar(byte)))."
    case .invalidEscape:
        return "Invalid character escape sequence."
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
