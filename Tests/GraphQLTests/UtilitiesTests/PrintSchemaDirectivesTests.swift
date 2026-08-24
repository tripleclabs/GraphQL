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

private func memberDirectiveDefinitions() throws -> [GraphQLDirective] {
    [
        try GraphQLDirective(
            name: "unique",
            locations: [.fieldDefinition, .enumValue, .inputFieldDefinition, .argumentDefinition]
        ),
    ]
}

@Suite struct PrintSchemaMemberDirectivesTests {
    @Test func printsDirectiveOnObjectField() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["email": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "User", member: "email"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("email: String @unique"))
    }

    @Test func printsDirectiveAfterDeprecatedOnField() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: [
                "old": GraphQLField(type: GraphQLString, deprecationReason: "gone"),
            ]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "User", member: "old"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("old: String @deprecated(reason: \"gone\") @unique"))
    }

    @Test func printsDirectiveOnEnumValue() throws {
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
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "Role", member: "ADMIN"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("  ADMIN @unique"))
    }

    @Test func printsDirectiveOnInputField() throws {
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
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "Filter", member: "q"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("q: String @unique"))
    }

    @Test func printsDirectiveOnFieldArgument() throws {
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "user": GraphQLField(
                    type: GraphQLString,
                    args: ["id": GraphQLArgument(type: GraphQLString)]
                ),
            ]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .argument(type: "Query", field: "user", argument: "id"): [
                    AppliedDirective(name: "unique"),
                ],
            ]
        )
        #expect(sdl.contains("user(id: String @unique): String"))
    }

    @Test func emittedSDLParsesCleanly() throws {
        let user = try GraphQLObjectType(
            name: "User",
            fields: ["email": GraphQLField(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        let schema = try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
        let sdl = printSchema(
            schema: schema,
            appliedDirectives: [
                .member(type: "User", member: "email"): [AppliedDirective(name: "unique")],
            ]
        )
        _ = try parse(source: Source(body: sdl))
    }

    @Test func outputIsDeterministicAcrossRuns() throws {
        func render() throws -> String {
            let user = try GraphQLObjectType(
                name: "User",
                fields: [
                    "email": GraphQLField(type: GraphQLString),
                    "name": GraphQLField(type: GraphQLString),
                ]
            )
            let query = try GraphQLObjectType(
                name: "Query",
                fields: ["user": GraphQLField(type: user)]
            )
            let schema = try GraphQLSchema(
                query: query,
                directives: specifiedDirectives + memberDirectiveDefinitions()
            )
            return printSchema(
                schema: schema,
                appliedDirectives: [
                    .member(type: "User", member: "email"): [
                        AppliedDirective(name: "unique"),
                    ],
                ]
            )
        }
        #expect(try render() == render())
    }
}

@Suite struct PrintSchemaDefinitionDirectivesTests {
    private func linkSchema() throws -> GraphQLSchema {
        let link = try GraphQLDirective(
            name: "link",
            locations: [.schema],
            args: ["url": GraphQLArgument(type: GraphQLString)]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["a": GraphQLField(type: GraphQLString)]
        )
        return try GraphQLSchema(query: query, directives: specifiedDirectives + [link])
    }

    @Test func schemaBlockIsOmittedWithoutSchemaDirective() throws {
        let sdl = printSchema(schema: try linkSchema())
        // Not `contains("schema")` — the directive definition line contains
        // "on SCHEMA", and lowercase "schema" only ever appears as the block.
        #expect(!sdl.contains("schema {"))
        #expect(!sdl.hasPrefix("schema"))
    }

    @Test func schemaDirectiveForcesSchemaBlockToPrint() throws {
        let sdl = printSchema(
            schema: try linkSchema(),
            appliedDirectives: [
                .schema: [
                    AppliedDirective(name: "link", arguments: [("url", "https://example.com/v1")]),
                ],
            ]
        )
        #expect(sdl.contains("schema @link(url: \"https://example.com/v1\") {"))
        #expect(sdl.contains("  query: Query"))
    }
}

/// `printInterface` carries its own copy of the `printFields` call that
/// `printObject` makes. These pin the interface copy independently, so a wrong
/// `typeName` threaded through it cannot hide behind the object-side tests.
@Suite struct PrintSchemaInterfaceMemberDirectivesTests {
    private func schema() throws -> GraphQLSchema {
        let node = try GraphQLInterfaceType(
            name: "Node",
            fields: [
                "id": GraphQLField(
                    type: GraphQLString,
                    args: ["raw": GraphQLArgument(type: GraphQLString)]
                ),
            ]
        )
        let user = try GraphQLObjectType(
            name: "User",
            fields: [
                "id": GraphQLField(
                    type: GraphQLString,
                    args: ["raw": GraphQLArgument(type: GraphQLString)]
                ),
            ],
            interfaces: [node]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["user": GraphQLField(type: user)]
        )
        return try GraphQLSchema(
            query: query,
            types: [node, user],
            directives: specifiedDirectives + memberDirectiveDefinitions()
        )
    }

    @Test func printsDirectiveOnInterfaceField() throws {
        let sdl = printSchema(
            schema: try schema(),
            appliedDirectives: [
                .member(type: "Node", member: "id"): [AppliedDirective(name: "unique")],
            ]
        )
        #expect(sdl.contains("interface Node {"))
        #expect(sdl.contains("id(raw: String): String @unique"))
        // The identically-named object field must NOT pick it up.
        #expect(!sdl.contains("type User implements Node {\n  id(raw: String): String @unique"))
    }

    @Test func printsDirectiveOnInterfaceFieldArgument() throws {
        let sdl = printSchema(
            schema: try schema(),
            appliedDirectives: [
                .argument(type: "Node", field: "id", argument: "raw"): [
                    AppliedDirective(name: "unique"),
                ],
            ]
        )
        #expect(sdl.contains("id(raw: String @unique): String"))
    }
}
