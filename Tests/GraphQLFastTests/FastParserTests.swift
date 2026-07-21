@testable import GraphQL
import GraphQLFast
import Testing

@Suite struct FastParserTests {
    @Test(arguments: benchmarkSuccessQueries)
    func benchmarkDocumentsMatchReferenceStructure(source: String) throws {
        let reference = try parse(source: source, noLocation: true)
        let fast = try FastParser.parse(source)

        #expect(normalize(reference) == normalize(fast))
    }

    @Test func malformedBenchmarkDocumentFailsBothParsers() {
        let source = """
        query MalformedQuery {
          person(id: "1") {
            id
            name
        """

        #expect(throws: (any Error).self) {
            try parse(source: source, noLocation: true)
        }
        #expect(throws: FastParseError.self) {
            try FastParser.parse(source)
        }
    }

    @Test func storesNestedSelectionsAsLinkedArenaEntries() throws {
        let document = try FastParser.parse("{ a { b c { d } } e }")
        #expect(document.operations.count == 1)
        #expect(document.selectionSets.count == 3)
        #expect(document.selections.count == 5)
        #expect(document.selectionSets[Int(document.operations[0].selectionSet)].selectionCount == 2)
    }
}

private let benchmarkSuccessQueries = [
    """
    query SingleItem {
      person(id: "1") {
        id
        name
        birthYear
        species { name }
      }
    }
    """,
    """
    query ListItems {
      people {
        id
        name
        birthYear
        species { id name classification }
      }
    }
    """,
    """
    query InvalidField {
      person(id: "1") { id starships }
    }
    """,
    """
    query InvalidType {
      person(id: "1") {
        id
        ... on Vehicle { name }
      }
    }
    """,
    """
    query Introspection {
      __schema {
        queryType { name }
        types {
          kind
          name
          fields(includeDeprecated: true) {
            name
            args { name type { kind name ofType { kind name } } }
            type { kind name ofType { kind name } }
          }
          inputFields { name type { kind name ofType { kind name } } }
          interfaces { kind name }
          enumValues(includeDeprecated: true) { name }
          possibleTypes { kind name }
        }
        directives {
          name
          locations
          args { name type { kind name ofType { kind name } } }
        }
      }
    }
    """,
]

private struct NormalizedOperation: Equatable {
    let kind: String
    let name: String?
    let selections: [NormalizedSelection]
}

private struct NormalizedArgument: Equatable {
    let name: String
    let value: String
}

private indirect enum NormalizedSelection: Equatable {
    case field(
        alias: String?,
        name: String,
        arguments: [NormalizedArgument],
        selections: [NormalizedSelection]
    )
    case inlineFragment(typeCondition: String?, selections: [NormalizedSelection])
    case fragmentSpread(name: String)
}

private func normalize(_ document: Document) -> [NormalizedOperation] {
    document.definitions.compactMap { definition in
        guard let operation = definition as? OperationDefinition else { return nil }
        return NormalizedOperation(
            kind: operation.operation.rawValue,
            name: operation.name?.value,
            selections: normalize(operation.selectionSet)
        )
    }
}

private func normalize(_ selectionSet: SelectionSet) -> [NormalizedSelection] {
    selectionSet.selections.map { selection in
        if let field = selection as? Field {
            return .field(
                alias: field.alias?.value,
                name: field.name.value,
                arguments: field.arguments.map {
                    NormalizedArgument(name: $0.name.value, value: print(ast: $0.value))
                },
                selections: field.selectionSet.map(normalize) ?? []
            )
        }
        if let fragment = selection as? InlineFragment {
            return .inlineFragment(
                typeCondition: fragment.typeCondition?.name.value,
                selections: normalize(fragment.selectionSet)
            )
        }
        let fragment = selection as! FragmentSpread
        return .fragmentSpread(name: fragment.name.value)
    }
}

private func normalize(_ document: FastDocument) -> [NormalizedOperation] {
    let bytes = Array(document.source.utf8)
    return document.operations.map { operation in
        NormalizedOperation(
            kind: {
                switch operation.kind {
                case .query: return "query"
                case .mutation: return "mutation"
                case .subscription: return "subscription"
                }
            }(),
            name: operation.name.map { slice(bytes, $0) },
            selections: normalize(document, selectionSet: operation.selectionSet, bytes: bytes)
        )
    }
}

private func normalize(
    _ document: FastDocument,
    selectionSet: UInt32,
    bytes: [UInt8]
) -> [NormalizedSelection] {
    var result: [NormalizedSelection] = []
    var selectionID = document.selectionSets[Int(selectionSet)].firstSelection
    while let id = selectionID {
        let selection = document.selections[Int(id)]
        switch selection.kind {
        case .field:
            let argumentStart = Int(selection.arguments.start)
            let argumentEnd = argumentStart + Int(selection.arguments.count)
            let arguments = document.arguments[argumentStart ..< argumentEnd].map { argument in
                NormalizedArgument(
                    name: slice(bytes, argument.name),
                    value: slice(bytes, document.values[Int(argument.value)].source)
                )
            }
            result.append(.field(
                alias: selection.alias.map { slice(bytes, $0) },
                name: slice(bytes, selection.name!),
                arguments: arguments,
                selections: selection.selectionSet.map {
                    normalize(document, selectionSet: $0, bytes: bytes)
                } ?? []
            ))
        case .inlineFragment:
            result.append(.inlineFragment(
                typeCondition: selection.typeCondition.map { slice(bytes, $0) },
                selections: normalize(document, selectionSet: selection.selectionSet!, bytes: bytes)
            ))
        case .fragmentSpread:
            result.append(.fragmentSpread(name: slice(bytes, selection.name!)))
        }
        selectionID = selection.nextSibling
    }
    return result
}

private func slice(_ bytes: [UInt8], _ range: FastSourceRange) -> String {
    String(decoding: bytes[Int(range.start) ..< Int(range.end)], as: UTF8.self)
}
