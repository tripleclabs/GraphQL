public struct FastParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let position: UInt32
    public let reason: Reason

    public enum Reason: Sendable, Equatable {
        case expected(FastTokenKind)
        case expectedName
        case expectedValue
        case unsupported(String)
    }

    public var description: String {
        "GraphQL parse error at byte \(position): \(reason)"
    }
}

/// Parses executable GraphQL documents into compact, index-addressed arenas.
public enum FastParser {
    public static func parse(_ source: String) throws -> FastDocument {
        if let document = try source.utf8.withContiguousStorageIfAvailable({ bytes in
            try parse(source: source, bytes: bytes)
        }) {
            return document
        }

        let copiedBytes = ContiguousArray(source.utf8)
        return try copiedBytes.withUnsafeBufferPointer { bytes in
            try parse(source: source, bytes: bytes)
        }
    }

    private static func parse(
        source: String,
        bytes: UnsafeBufferPointer<UInt8>
    ) throws -> FastDocument {
        let tokens = try FastLexer.tokenize(bytes)
        var parser = Parser(source: source, bytes: bytes, tokens: tokens)
        return try parser.parseDocument()
    }
}

private struct Parser {
    let source: String
    let bytes: UnsafeBufferPointer<UInt8>
    let tokens: ContiguousArray<FastToken>
    var cursor = 0
    var document: FastDocument

    init(
        source: String,
        bytes: UnsafeBufferPointer<UInt8>,
        tokens: ContiguousArray<FastToken>
    ) {
        self.source = source
        self.bytes = bytes
        self.tokens = tokens
        document = FastDocument(source: source)
        document.operations.reserveCapacity(1)
        document.selectionSets.reserveCapacity(8)
        document.selections.reserveCapacity(max(8, tokens.count / 3))
        document.arguments.reserveCapacity(4)
        document.values.reserveCapacity(4)
    }

    mutating func parseDocument() throws -> FastDocument {
        while current.kind != .eof {
            try parseOperation()
        }
        guard !document.operations.isEmpty else {
            throw parseError(.expected(.leftBrace))
        }
        return document
    }

    mutating func parseOperation() throws {
        if current.kind == .leftBrace {
            let selectionSet = try parseSelectionSet()
            document.operations.append(FastOperation(
                kind: .query,
                name: nil,
                selectionSet: selectionSet
            ))
            return
        }

        let operationToken = try expectName()
        let operationKind: FastOperation.Kind
        if matches(operationToken, "query") {
            operationKind = .query
        } else if matches(operationToken, "mutation") {
            operationKind = .mutation
        } else if matches(operationToken, "subscription") {
            operationKind = .subscription
        } else {
            throw parseError(.unsupported("non-executable definition"), at: operationToken)
        }

        var name: FastSourceRange?
        if current.kind == .name {
            name = advance().range
        }
        if current.kind == .leftParenthesis {
            throw parseError(.unsupported("variable definitions"))
        }
        if current.kind == .at {
            throw parseError(.unsupported("operation directives"))
        }
        let selectionSet = try parseSelectionSet()
        document.operations.append(FastOperation(
            kind: operationKind,
            name: name,
            selectionSet: selectionSet
        ))
    }

    mutating func parseSelectionSet() throws -> UInt32 {
        _ = try expect(.leftBrace)
        let setID = UInt32(document.selectionSets.count)
        document.selectionSets.append(FastSelectionSet(
            firstSelection: nil,
            selectionCount: 0
        ))

        var previous: UInt32?
        while current.kind != .rightBrace {
            if current.kind == .eof {
                throw parseError(.expected(.rightBrace))
            }
            let selectionID = try parseSelection()
            if let previous {
                document.selections[Int(previous)].nextSibling = selectionID
            } else {
                document.selectionSets[Int(setID)].firstSelection = selectionID
            }
            document.selectionSets[Int(setID)].selectionCount += 1
            previous = selectionID
        }
        _ = advance()
        return setID
    }

    mutating func parseSelection() throws -> UInt32 {
        if current.kind == .spread {
            _ = advance()
            if current.kind == .name, matches(current, "on") {
                _ = advance()
                let typeCondition = try expectName().range
                if current.kind == .at {
                    throw parseError(.unsupported("inline-fragment directives"))
                }
                let placeholder = appendSelectionPlaceholder()
                let childSet = try parseSelectionSet()
                document.selections[Int(placeholder)] = FastSelection(
                    kind: .inlineFragment,
                    name: nil,
                    alias: nil,
                    arguments: .empty,
                    selectionSet: childSet,
                    typeCondition: typeCondition,
                    nextSibling: nil
                )
                return placeholder
            }

            let name = try expectName().range
            if current.kind == .at {
                throw parseError(.unsupported("fragment-spread directives"))
            }
            let selection = FastSelection(
                kind: .fragmentSpread,
                name: name,
                alias: nil,
                arguments: .empty,
                selectionSet: nil,
                typeCondition: nil,
                nextSibling: nil
            )
            document.selections.append(selection)
            return UInt32(document.selections.count - 1)
        }

        var name = try expectName().range
        var alias: FastSourceRange?
        if current.kind == .colon {
            _ = advance()
            alias = name
            name = try expectName().range
        }

        let arguments = try parseArguments()
        if current.kind == .at {
            throw parseError(.unsupported("field directives"))
        }
        let placeholder = appendSelectionPlaceholder()
        let childSet = current.kind == .leftBrace ? try parseSelectionSet() : nil
        document.selections[Int(placeholder)] = FastSelection(
            kind: .field,
            name: name,
            alias: alias,
            arguments: arguments,
            selectionSet: childSet,
            typeCondition: nil,
            nextSibling: nil
        )
        return placeholder
    }

    mutating func parseArguments() throws -> FastArenaRange {
        guard current.kind == .leftParenthesis else { return .empty }
        _ = advance()
        let start = UInt32(document.arguments.count)
        while current.kind != .rightParenthesis {
            if current.kind == .eof {
                throw parseError(.expected(.rightParenthesis))
            }
            let name = try expectName().range
            _ = try expect(.colon)
            let value = try parseValue()
            document.arguments.append(FastArgument(name: name, value: value))
        }
        _ = advance()
        return FastArenaRange(
            start: start,
            count: UInt32(document.arguments.count) - start
        )
    }

    mutating func parseValue() throws -> UInt32 {
        let token = current
        let kind: FastValue.Kind
        switch token.kind {
        case .dollar:
            _ = advance()
            let name = try expectName()
            let range = FastSourceRange(start: token.range.start, end: name.range.end)
            document.values.append(FastValue(kind: .variable, source: range, children: .empty))
            return UInt32(document.values.count - 1)
        case .integer: kind = .integer
        case .float: kind = .float
        case .string, .blockString: kind = .string
        case .name:
            if matches(token, "true") || matches(token, "false") {
                kind = .boolean
            } else if matches(token, "null") {
                kind = .null
            } else {
                kind = .enum
            }
        case .leftBracket, .leftBrace:
            throw parseError(.unsupported("list and object values"))
        default:
            throw parseError(.expectedValue)
        }
        _ = advance()
        document.values.append(FastValue(kind: kind, source: token.range, children: .empty))
        return UInt32(document.values.count - 1)
    }

    mutating func appendSelectionPlaceholder() -> UInt32 {
        let id = UInt32(document.selections.count)
        document.selections.append(FastSelection(
            kind: .field,
            name: nil,
            alias: nil,
            arguments: .empty,
            selectionSet: nil,
            typeCondition: nil,
            nextSibling: nil
        ))
        return id
    }

    var current: FastToken { tokens[cursor] }

    @discardableResult
    mutating func advance() -> FastToken {
        let token = current
        if token.kind != .eof { cursor += 1 }
        return token
    }

    mutating func expect(_ kind: FastTokenKind) throws -> FastToken {
        guard current.kind == kind else { throw parseError(.expected(kind)) }
        return advance()
    }

    mutating func expectName() throws -> FastToken {
        guard current.kind == .name else { throw parseError(.expectedName) }
        return advance()
    }

    func matches(_ token: FastToken, _ ascii: StaticString) -> Bool {
        let count = Int(token.range.end - token.range.start)
        guard count == ascii.utf8CodeUnitCount else { return false }
        return ascii.withUTF8Buffer { expected in
            let start = Int(token.range.start)
            for index in 0 ..< count where bytes[start + index] != expected[index] {
                return false
            }
            return true
        }
    }

    func parseError(
        _ reason: FastParseError.Reason,
        at token: FastToken? = nil
    ) -> FastParseError {
        FastParseError(position: (token ?? current).range.start, reason: reason)
    }
}
