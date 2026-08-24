@testable import GraphQL
import Testing

@Suite struct ASTFromValueStringTests {
    /// `StringValue.value` holds decoded text — the lexer turns `\/` into `/`
    /// and `\n` into a newline — so `astFromValue` must store raw text and let
    /// `printString` re-encode at print time. Encoding early double-escapes.
    @Test func stringValueHoldsDecodedText() throws {
        let node = try astFromValue(value: "http://x.com/y", type: GraphQLString)
        let stringValue = try #require(node as? StringValue)
        #expect(stringValue.value == "http://x.com/y")
    }

    @Test func slashesSurviveSDLRoundTrip() throws {
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "a": GraphQLField(
                    type: GraphQLString,
                    args: [
                        "u": GraphQLArgument(
                            type: GraphQLString,
                            defaultValue: "http://x.com/y"
                        ),
                    ]
                ),
            ]
        )
        let sdl = printSchema(schema: try GraphQLSchema(query: query))
        #expect(sdl.contains("u: String = \"http://x.com/y\""))
        // Printing the reparsed schema must be a fixed point.
        #expect(printSchema(schema: try buildSchema(source: sdl)) == sdl)
    }

    @Test func controlCharactersAreStillEscaped() throws {
        let node = try astFromValue(value: "a\nb\"c\\d", type: GraphQLString)
        let stringValue = try #require(node as? StringValue)
        #expect(stringValue.value == "a\nb\"c\\d")
        #expect(print(ast: stringValue) == "\"a\\nb\\\"c\\\\d\"")
    }
}
