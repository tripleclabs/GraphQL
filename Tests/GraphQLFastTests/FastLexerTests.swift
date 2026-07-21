@_spi(EngineV2Benchmark) @testable import GraphQL
import GraphQLFast
import Testing

@Suite struct FastLexerTests {
    @Test func tokenizesExecutableDocumentWithoutAllocatingTokenValues() throws {
        let tokens = try FastLexer.tokenize("query Hero($id: ID!) { person(id: $id) { name } }")

        #expect(tokens.map(\.kind) == [
            .name, .name, .leftParenthesis, .dollar, .name, .colon, .name, .bang,
            .rightParenthesis, .leftBrace, .name, .leftParenthesis, .name, .colon,
            .dollar, .name, .rightParenthesis, .leftBrace, .name, .rightBrace,
            .rightBrace, .eof,
        ])
    }

    @Test func skipsWhitespaceCommasCommentsAndBOM() throws {
        let tokens = try FastLexer.tokenize("\u{FEFF} # ignored\r\n, foo")
        #expect(tokens.count == 2)
        #expect(tokens[0].kind == .name)
        #expect(tokens[0].range == FastSourceRange(start: 17, end: 20))
    }

    @Test func recognizesNumbersStringsAndBlockStrings() throws {
        let tokens = try FastLexer.tokenize("-12 3.5 6e+2 \"value\\n\" \"\"\"block\"\"\"")
        #expect(tokens.map(\.kind) == [
            .integer, .float, .float, .string, .blockString, .eof,
        ])
    }

    @Test func rejectsLeadingZero() {
        #expect(throws: FastLexError.self) {
            try FastLexer.tokenize("01")
        }
    }

    @Test func rejectsUnterminatedSelectionString() {
        #expect(throws: FastLexError.self) {
            try FastLexer.tokenize("{ person(id: \"1) {")
        }
    }

    @Test func malformedBenchmarkQueryReachesEOFWithoutParserState() throws {
        let tokens = try FastLexer.tokenize("query Malformed { person(id: \"1\") { id name")
        #expect(tokens.last?.kind == .eof)
    }

    @Test(arguments: [
        "{ name }",
        "query Hero { hero { id name } }",
        "query Q($id: ID!) { person(id: $id) { name } }",
        "mutation M { update(id: 1, value: 2.5e-2) { ok } }",
        "{ field(arg: \"escaped \\\" value\") }",
        "{ field(arg: \"\"\"block value\"\"\") }",
        "{ ...Named ... on Person { name } }",
        "# comment\r\n{a,b,c}",
        "\u{FEFF} query BOM { field }",
        "[Int!]! & | @skip(if: true)",
    ])
    func tokenKindsAndRangesMatchReferenceLexer(source: String) throws {
        let fast = try FastLexer.tokenize(source)
        let reference = try referenceTokens(source)

        #expect(fast.count == reference.count)
        for (fastToken, referenceToken) in zip(fast, reference) {
            #expect(fastToken.kind == referenceToken.kind)
            #expect(Int(fastToken.range.start) == referenceToken.start)
            #expect(Int(fastToken.range.end) == referenceToken.end)
        }
    }

    @Test(arguments: [
        "?",
        "\u{0007}",
        "00",
        "-A",
        "1.",
        "1.0e",
        "1.0eA",
        #"{ field(arg: "bad \z esc") }"#,
        #"{ field(arg: "bad \u0XX1 esc") }"#,
        "{ field(arg: \"bad \u{0007} value\") }",
        "{ field(arg: \"multi\nline\") }",
        #"{ field(arg: "unterminated) }"#,
        "{ field(arg: \"\"\"bad \u{0007} block\"\"\") }",
        #"{ field(arg: """unterminated) }"#,
        "※",
    ])
    func adaptedPublicLexErrorsMatchReference(source: String) throws {
        let reference = try captureGraphQLError {
            try parse(source: source)
        }
        let fast = try captureGraphQLError {
            do {
                _ = try FastParser.parse(source)
            } catch {
                throw engineV2PublicParseError(error, source: source)
            }
        }

        #expect(fast.message == reference.message)
        #expect(fast.positions == reference.positions)
        #expect(fast.locations == reference.locations)
    }
}

private enum LexExpectedError: Error {
    case noneThrown
    case wrongType(any Error)
}

private func captureGraphQLError<T>(_ operation: () throws -> T) throws -> GraphQLError {
    do {
        _ = try operation()
        throw LexExpectedError.noneThrown
    } catch let error as GraphQLError {
        return error
    } catch {
        throw LexExpectedError.wrongType(error)
    }
}

private struct ReferenceToken {
    let kind: FastTokenKind
    let start: Int
    let end: Int
}

private func referenceTokens(_ source: String) throws -> [ReferenceToken] {
    let lexer = createLexer(source: Source(body: source))
    var result: [ReferenceToken] = []
    while true {
        let token = try lexer.advance()
        result.append(ReferenceToken(
            kind: fastKind(token.kind),
            start: token.start,
            end: token.end
        ))
        if token.kind == .eof { return result }
    }
}

private func fastKind(_ kind: Token.Kind) -> FastTokenKind {
    switch kind {
    case .eof: return .eof
    case .bang: return .bang
    case .dollar: return .dollar
    case .amp: return .ampersand
    case .openingParenthesis: return .leftParenthesis
    case .closingParenthesis: return .rightParenthesis
    case .spread: return .spread
    case .colon: return .colon
    case .equals: return .equals
    case .at: return .at
    case .openingBracket: return .leftBracket
    case .closingBracket: return .rightBracket
    case .openingBrace: return .leftBrace
    case .pipe: return .pipe
    case .closingBrace: return .rightBrace
    case .name: return .name
    case .int: return .integer
    case .float: return .float
    case .string: return .string
    case .blockstring: return .blockString
    case .sof, .comment:
        preconditionFailure("Reference lexer does not emit \(kind) from advance()")
    }
}
