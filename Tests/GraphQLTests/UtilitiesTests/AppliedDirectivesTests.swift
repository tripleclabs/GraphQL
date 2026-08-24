@testable import GraphQL
import Testing

private func schemaWithDirectives() throws -> GraphQLSchema {
    let role = try GraphQLEnumType(
        name: "Role",
        values: ["ADMIN": GraphQLEnumValue(value: .string("ADMIN"))]
    )
    let auth = try GraphQLDirective(
        name: "auth",
        locations: [.fieldDefinition],
        args: ["role": GraphQLArgument(type: role)]
    )
    let tag = try GraphQLDirective(
        name: "tag",
        locations: [.fieldDefinition, .object],
        args: ["name": GraphQLArgument(type: GraphQLString)]
    )
    let flag = try GraphQLDirective(name: "flag", locations: [.object])
    let query = try GraphQLObjectType(
        name: "Query",
        fields: ["a": GraphQLField(type: GraphQLString)]
    )
    return try GraphQLSchema(
        query: query,
        types: [role],
        directives: specifiedDirectives + [auth, tag, flag]
    )
}

@Suite struct AppliedDirectivePrintingTests {
    @Test func printsNothingWhenTargetHasNoDirectives() throws {
        let schema = try schemaWithDirectives()
        let result = printAppliedDirectives(.type("User"), [:], schema)
        #expect(result == "")
    }

    @Test func printsDirectiveWithNoArguments() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "flag", arguments: [])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == " @flag")
    }

    @Test func printsStringArgumentQuoted() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "tag", arguments: [("name", "pii")])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == " @tag(name: \"pii\")")
    }

    @Test func printsEnumArgumentUnquoted() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .member(type: "User", member: "email"): [
                AppliedDirective(name: "auth", arguments: [("role", "ADMIN")]),
            ],
        ]
        let result = printAppliedDirectives(.member(type: "User", member: "email"), map, schema)
        #expect(result == " @auth(role: ADMIN)")
    }

    @Test func printsMultipleDirectivesInDeclarationOrder() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [
                AppliedDirective(name: "flag", arguments: []),
                AppliedDirective(name: "tag", arguments: [("name", "pii")]),
            ],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == " @flag @tag(name: \"pii\")")
    }

    @Test func skipsUndeclaredDirectiveRatherThanTrapping() throws {
        let schema = try schemaWithDirectives()
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "nope", arguments: [])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, schema) == "")
    }

    @Test func coercionErrorsAreEmptyForValidValues() throws {
        let tag = try GraphQLDirective(
            name: "tag",
            locations: [.object],
            args: ["name": GraphQLArgument(type: GraphQLString)]
        )
        let applied = AppliedDirective(name: "tag", arguments: [("name", "pii")])
        #expect(applied.coercionErrors(against: tag).isEmpty)
    }

    @Test func coercionErrorsReportUncoercibleValues() throws {
        let count = try GraphQLDirective(
            name: "count",
            locations: [.object],
            args: ["n": GraphQLArgument(type: GraphQLInt)]
        )
        let applied = AppliedDirective(name: "count", arguments: [("n", "not a number")])
        #expect(!applied.coercionErrors(against: count).isEmpty)
    }
}

@Suite struct AppliedDirectiveNullAndPartialTests {
    private func schema() throws -> GraphQLSchema {
        let nullable = try GraphQLDirective(
            name: "n",
            locations: [.object],
            args: ["v": GraphQLArgument(type: GraphQLString)]
        )
        let required = try GraphQLDirective(
            name: "r",
            locations: [.object],
            args: ["v": GraphQLArgument(type: GraphQLNonNull(GraphQLString))]
        )
        let counted = try GraphQLDirective(
            name: "c",
            locations: [.object],
            args: ["n": GraphQLArgument(type: GraphQLNonNull(GraphQLInt))]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["a": GraphQLField(type: GraphQLString)]
        )
        return try GraphQLSchema(
            query: query,
            directives: specifiedDirectives + [nullable, required, counted]
        )
    }

    @Test func explicitNullOnNullableArgumentRenders() throws {
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "n", arguments: [("v", nil)])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, try schema()) == " @n(v: null)")
    }

    @Test func explicitNullOnNullableArgumentIsNotACoercionError() throws {
        let nullable = try GraphQLDirective(
            name: "n",
            locations: [.object],
            args: ["v": GraphQLArgument(type: GraphQLString)]
        )
        let applied = AppliedDirective(name: "n", arguments: [("v", nil)])
        #expect(applied.coercionErrors(against: nullable).isEmpty)
    }

    @Test func explicitNullOnNonNullArgumentIsACoercionError() throws {
        let required = try GraphQLDirective(
            name: "r",
            locations: [.object],
            args: ["v": GraphQLArgument(type: GraphQLNonNull(GraphQLString))]
        )
        let applied = AppliedDirective(name: "r", arguments: [("v", nil)])
        #expect(!applied.coercionErrors(against: required).isEmpty)
    }

    @Test func uncoercibleArgumentSkipsTheWholeDirective() throws {
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "c", arguments: [("n", "nope")])],
        ]
        // Must not emit a bare "@c" that has silently lost a required argument.
        #expect(printAppliedDirectives(.type("User"), map, try schema()) == "")
    }

    @Test func unknownArgumentNameSkipsTheWholeDirective() throws {
        let map: AppliedDirectiveMap = [
            .type("User"): [AppliedDirective(name: "n", arguments: [("nope", "x")])],
        ]
        #expect(printAppliedDirectives(.type("User"), map, try schema()) == "")
    }
}
