@testable import GraphQL
import GraphQLFast
import Testing

@Suite struct FastStringValueTests {
    @Test(arguments: stringLiteralSources)
    func decodedStringsMatchReference(source: String) throws {
        let reference = try parse(source: source, noLocation: true)
        let operation = try #require(reference.definitions.first as? OperationDefinition)
        let field = try #require(operation.selectionSet.selections.first as? Field)
        let referenceValue = try #require(field.arguments.first?.value as? StringValue)

        let fast = try FastParser.parse(source)
        let argument = try #require(fast.arguments.first)

        #expect(try fast.decodedString(valueAt: argument.value) == referenceValue.value)
    }

    @Test func rejectsNonStringValuesAndInvalidIndexes() throws {
        let fast = try FastParser.parse("{ field(value: 42) }")
        let value = try #require(fast.arguments.first?.value)

        #expect(throws: FastValueAccessError.expectedString) {
            try fast.decodedString(valueAt: value)
        }
        #expect(throws: FastValueAccessError.indexOutOfBounds) {
            try fast.decodedString(valueAt: UInt32.max)
        }
    }
}

private let stringLiteralSources = [
    #"{ field(value: "plain text") }"#,
    #"{ field(value: "quote: \" slash: \/ backslash: \\ tab: \t newline: \n") }"#,
    #"{ field(value: "unicode: \u0041 snowman: ☃️") }"#,
    #"{ field(value: "") }"#,
    #"""
    {
      field(value: """
        first
          second
        third
      """)
    }
    """#,
    #"""
    { field(value: """embedded \""" quotes""") }
    """#,
    "{ field(value: \"\"\"first\r\n  second\rthird\"\"\") }",
]
