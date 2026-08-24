import GraphQL
import Testing

@Suite struct SpecifiedDirectivesVisibilityTests {
    @Test func specifiedDirectivesIsPubliclyVisible() throws {
        let names = specifiedDirectives.map { $0.name }.sorted()
        #expect(names == ["deprecated", "include", "oneOf", "skip", "specifiedBy"])
    }

    @Test func customDirectivesCanBeMergedWithSpecified() throws {
        let custom = try GraphQLDirective(name: "model", locations: [.object])
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["a": GraphQLField(type: GraphQLString)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + [custom]
        )
        let names = schema.directives.map { $0.name }
        #expect(names.contains("skip"))
        #expect(names.contains("include"))
        #expect(names.contains("model"))
    }
}
