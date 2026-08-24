@testable import GraphQL
import Testing

private func directiveDefinitions() throws -> [GraphQLDirective] {
    [
        try GraphQLDirective(
            name: "model",
            locations: [.object, .interface, .union, .enum, .inputObject, .scalar],
            args: ["table": GraphQLArgument(type: GraphQLString)]
        ),
    ]
}

@Suite struct PrintSchemaTypeDirectivesTests {
    @Test func printsDirectiveOnObjectType() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["id": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .type("User"): [AppliedDirective(name: "model", arguments: [("table", "users")])],
            ]
        )
        #expect(sdl.contains("type User @model(table: \"users\") {"))
    }

    @Test func printsDirectiveAfterImplementsClause() throws {
        let node = try GraphQLInterfaceType(
            name: "Node",
            fields: ["id": GraphQLField(type: GraphQLString)]
        )
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["id": GraphQLField(type: GraphQLString)],
            interfaces: [node]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            types: [node, user],
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("User"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("type User implements Node @model {"))
    }

    @Test func printsDirectiveOnEnumBeforeBrace() throws {
        let role = try GraphQLEnumType(
            name: "Role",
            values: ["ADMIN": GraphQLEnumValue(value: .string("ADMIN"))]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["role": GraphQLField(type: role)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("Role"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("enum Role @model {"))
    }

    @Test func printsDirectiveOnUnionBeforeEquals() throws {
        let a = try GraphQLObjectType(name: "A", fields: ["x": GraphQLField(type: GraphQLString)])
        let b = try GraphQLObjectType(name: "B", fields: ["y": GraphQLField(type: GraphQLString)])
        let result = try GraphQLUnionType(name: "Result", types: [a, b])
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["r": GraphQLField(type: result)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("Result"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("union Result @model = A | B"))
    }

    @Test func printsDirectiveOnInputObjectBeforeBrace() throws {
        let filter = try GraphQLInputObjectType(
            name: "Filter",
            fields: ["q": InputObjectField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "search": GraphQLField(
                    type: GraphQLString,
                    args: ["filter": GraphQLArgument(type: filter)]
                ),
            ]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("Filter"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("input Filter @model {"))
    }

    @Test func printsDirectiveOnScalar() throws {
        let dateTime = try GraphQLScalarType(name: "DateTime")
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["now": GraphQLField(type: dateTime)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + directiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [.type("DateTime"): [AppliedDirective(name: "model")]]
        )
        #expect(sdl.contains("scalar DateTime @model"))
    }

    @Test func emptyMapProducesIdenticalOutputToLegacyEntryPoint() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["id": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(query: query)
        #expect(printSchema(schema: schema) == printSchema(schema: schema, appliedDirectives: [:]))
    }
}
