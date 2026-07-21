public struct FastParseError: Error, Sendable, Equatable, CustomStringConvertible {
    public let position: UInt32
    public let reason: Reason
    public let found: FastToken

    public enum Reason: Sendable, Equatable {
        case expected(FastTokenKind)
        case expectedKeyword(String)
        case expectedName
        case expectedValue
        case unexpected
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
            if current.kind == .name, matches(current, "fragment") {
                try parseFragmentDefinition()
            } else {
                try parseOperation()
            }
        }
        guard !document.operations.isEmpty || !document.fragments.isEmpty else {
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
                variableDefinitions: .empty,
                directives: .empty,
                selectionSet: selectionSet
            ))
            return
        }

        guard current.kind == .name else { throw parseError(.unexpected) }
        let operationToken = advance()
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
        let variableDefinitions = try parseVariableDefinitions()
        let directives = try parseDirectives()
        let selectionSet = try parseSelectionSet()
        document.operations.append(FastOperation(
            kind: operationKind,
            name: name,
            variableDefinitions: variableDefinitions,
            directives: directives,
            selectionSet: selectionSet
        ))
    }

    mutating func parseFragmentDefinition() throws {
        _ = advance() // fragment
        let name = try expectName()
        if matches(name, "on") {
            throw parseError(.unexpected, at: name)
        }
        let on = try expectName()
        guard matches(on, "on") else {
            throw parseError(.expectedKeyword("on"), at: on)
        }
        let typeCondition = try expectName().range
        let directives = try parseDirectives()
        let selectionSet = try parseSelectionSet()
        document.fragments.append(FastFragment(
            name: name.range,
            typeCondition: typeCondition,
            directives: directives,
            selectionSet: selectionSet
        ))
    }

    mutating func parseVariableDefinitions() throws -> FastArenaRange {
        guard current.kind == .leftParenthesis else { return .empty }
        _ = advance()
        let start = UInt32(document.variableDefinitions.count)
        while current.kind != .rightParenthesis {
            _ = try expect(.dollar)
            let name = try expectName().range
            _ = try expect(.colon)
            let type = try parseTypeReference()
            var defaultValue: UInt32?
            if current.kind == .equals {
                _ = advance()
                defaultValue = try parseValue(isConst: true)
            }
            let directives = try parseDirectives()
            document.variableDefinitions.append(FastVariableDefinition(
                name: name,
                type: type,
                defaultValue: defaultValue,
                directives: directives
            ))
        }
        _ = advance()
        return FastArenaRange(
            start: start,
            count: UInt32(document.variableDefinitions.count) - start
        )
    }

    mutating func parseTypeReference() throws -> UInt32 {
        let typeID: UInt32
        if current.kind == .leftBracket {
            _ = advance()
            let wrappedType = try parseTypeReference()
            _ = try expect(.rightBracket)
            typeID = UInt32(document.types.count)
            document.types.append(FastTypeReference(
                kind: .list,
                name: nil,
                wrappedType: wrappedType
            ))
        } else {
            let name = try expectName().range
            typeID = UInt32(document.types.count)
            document.types.append(FastTypeReference(
                kind: .named,
                name: name,
                wrappedType: nil
            ))
        }
        if current.kind == .bang {
            _ = advance()
            let nonNullID = UInt32(document.types.count)
            document.types.append(FastTypeReference(
                kind: .nonNull,
                name: nil,
                wrappedType: typeID
            ))
            return nonNullID
        }
        return typeID
    }

    mutating func parseSelectionSet() throws -> UInt32 {
        _ = try expect(.leftBrace)
        let setID = UInt32(document.selectionSets.count)
        document.selectionSets.append(FastSelectionSet(
            firstSelection: nil,
            selectionCount: 0
        ))

        if current.kind == .rightBrace {
            throw parseError(.expectedName)
        }

        var previous: UInt32?
        while current.kind != .rightBrace {
            if current.kind == .eof {
                throw parseError(.expectedName)
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
            var typeCondition: FastSourceRange?
            if current.kind == .name, matches(current, "on") {
                _ = advance()
                typeCondition = try expectName().range
            }
            if typeCondition != nil || current.kind == .at || current.kind == .leftBrace {
                let directives = try parseDirectives()
                let placeholder = appendSelectionPlaceholder()
                let childSet = try parseSelectionSet()
                document.selections[Int(placeholder)] = FastSelection(
                    kind: .inlineFragment,
                    name: nil,
                    alias: nil,
                    arguments: .empty,
                    directives: directives,
                    selectionSet: childSet,
                    typeCondition: typeCondition,
                    nextSibling: nil
                )
                return placeholder
            }

            let name = try expectName().range
            let directives = try parseDirectives()
            let selection = FastSelection(
                kind: .fragmentSpread,
                name: name,
                alias: nil,
                arguments: .empty,
                directives: directives,
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
        let directives = try parseDirectives()
        let placeholder = appendSelectionPlaceholder()
        let childSet = current.kind == .leftBrace ? try parseSelectionSet() : nil
        document.selections[Int(placeholder)] = FastSelection(
            kind: .field,
            name: name,
            alias: alias,
            arguments: arguments,
            directives: directives,
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

    mutating func parseDirectives() throws -> FastArenaRange {
        guard current.kind == .at else { return .empty }
        let start = UInt32(document.directives.count)
        while current.kind == .at {
            _ = advance()
            let name = try expectName().range
            let arguments = try parseArguments()
            document.directives.append(FastDirective(name: name, arguments: arguments))
        }
        return FastArenaRange(
            start: start,
            count: UInt32(document.directives.count) - start
        )
    }

    mutating func parseValue(isConst: Bool = false) throws -> UInt32 {
        let token = current
        let kind: FastValue.Kind
        switch token.kind {
        case .dollar:
            if isConst { throw parseError(.expectedValue) }
            _ = advance()
            let name = try expectName()
            let range = FastSourceRange(start: token.range.start, end: name.range.end)
            document.values.append(FastValue(
                kind: .variable,
                source: range,
                firstChild: nil,
                childCount: 0,
                nextSibling: nil
            ))
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
        case .leftBracket:
            return try parseListValue(isConst: isConst)
        case .leftBrace:
            return try parseObjectValue(isConst: isConst)
        default:
            throw parseError(.expectedValue)
        }
        _ = advance()
        document.values.append(FastValue(
            kind: kind,
            source: token.range,
            firstChild: nil,
            childCount: 0,
            nextSibling: nil
        ))
        return UInt32(document.values.count - 1)
    }

    mutating func parseListValue(isConst: Bool) throws -> UInt32 {
        let startToken = advance()
        let listID = appendValuePlaceholder(kind: .list, start: startToken.range.start)
        var firstChild: UInt32?
        var previous: UInt32?
        var count: UInt32 = 0
        while current.kind != .rightBracket {
            if current.kind == .eof { throw parseError(.expected(.rightBracket)) }
            let child = try parseValue(isConst: isConst)
            if let previous {
                document.values[Int(previous)].nextSibling = child
            } else {
                firstChild = child
            }
            previous = child
            count += 1
        }
        let endToken = advance()
        document.values[Int(listID)] = FastValue(
            kind: .list,
            source: FastSourceRange(start: startToken.range.start, end: endToken.range.end),
            firstChild: firstChild,
            childCount: count,
            nextSibling: nil
        )
        return listID
    }

    mutating func parseObjectValue(isConst: Bool) throws -> UInt32 {
        let startToken = advance()
        let objectID = appendValuePlaceholder(kind: .object, start: startToken.range.start)
        var firstField: UInt32?
        var previous: UInt32?
        var count: UInt32 = 0
        while current.kind != .rightBrace {
            if current.kind == .eof { throw parseError(.expected(.rightBrace)) }
            let name = try expectName().range
            _ = try expect(.colon)
            let value = try parseValue(isConst: isConst)
            let fieldID = UInt32(document.objectFields.count)
            document.objectFields.append(FastObjectField(
                name: name,
                value: value,
                nextSibling: nil
            ))
            if let previous {
                document.objectFields[Int(previous)].nextSibling = fieldID
            } else {
                firstField = fieldID
            }
            previous = fieldID
            count += 1
        }
        let endToken = advance()
        document.values[Int(objectID)] = FastValue(
            kind: .object,
            source: FastSourceRange(start: startToken.range.start, end: endToken.range.end),
            firstChild: firstField,
            childCount: count,
            nextSibling: nil
        )
        return objectID
    }

    mutating func appendSelectionPlaceholder() -> UInt32 {
        let id = UInt32(document.selections.count)
        document.selections.append(FastSelection(
            kind: .field,
            name: nil,
            alias: nil,
            arguments: .empty,
            directives: .empty,
            selectionSet: nil,
            typeCondition: nil,
            nextSibling: nil
        ))
        return id
    }

    mutating func appendValuePlaceholder(
        kind: FastValue.Kind,
        start: UInt32
    ) -> UInt32 {
        let id = UInt32(document.values.count)
        document.values.append(FastValue(
            kind: kind,
            source: FastSourceRange(start: start, end: start),
            firstChild: nil,
            childCount: 0,
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
        let found = token ?? current
        return FastParseError(position: found.range.start, reason: reason, found: found)
    }
}
