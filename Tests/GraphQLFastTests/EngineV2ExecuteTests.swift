@_spi(EngineV2Benchmark) @testable import GraphQL
import GraphQLFast
import Testing

/// Differential coverage for the Engine V2 `single_item` vertical slice. Every supported case is
/// compared against Engine V1's public result so the fast path can only pass by matching the
/// reference engine.
@Suite struct EngineV2ExecuteTests {
    static let query = """
    query SingleItem {
      person(id: "1") {
        id
        name
        birthYear
        species { id name classification }
      }
    }
    """

    static func makeSchema() throws -> GraphQLSchema {
        let species = try GraphQLObjectType(
            name: "Species",
            fields: [
                "id": GraphQLField(type: GraphQLNonNull(GraphQLID)),
                "name": GraphQLField(type: GraphQLNonNull(GraphQLString)),
                "classification": GraphQLField(type: GraphQLString),
            ]
        )
        let person = try GraphQLObjectType(
            name: "Person",
            fields: [
                "id": GraphQLField(type: GraphQLNonNull(GraphQLID)),
                "name": GraphQLField(type: GraphQLNonNull(GraphQLString)),
                "birthYear": GraphQLField(type: GraphQLString),
                "species": GraphQLField(type: species),
            ]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "person": GraphQLField(
                    type: person,
                    args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))],
                    fastResolve: { source in
                        (source as? [String: any Sendable])?["person"]
                    }
                ),
                "people": GraphQLField(
                    type: GraphQLNonNull(GraphQLList(GraphQLNonNull(person))),
                    fastResolve: { source in
                        (source as? [String: any Sendable])?["people"]
                    }
                ),
            ]
        )
        return try GraphQLSchema(query: query)
    }

    static let listQuery = """
    query ListItems {
      people {
        id
        name
        birthYear
        species { id name classification }
      }
    }
    """

    /// Runs the query through both engines and asserts the fast path was eligible and matches
    /// Engine V1 on data and (message-normalized) errors.
    static func expectMatch(
        rootValue: [String: any Sendable],
        query: String = EngineV2ExecuteTests.query
    ) async throws {
        let schema = try makeSchema()
        let reference = try await graphql(schema: schema, request: query, rootValue: rootValue)
        let fast = try #require(
            engineV2ExecuteSingleItem(schema, query, rootValue: rootValue),
            "Engine V2 should be eligible for this document"
        )
        #expect(fast.data == reference.data)
        #expect(fast.errors.map(\.message).sorted() == reference.errors.map(\.message).sorted())
    }

    static let fullPerson: [String: any Sendable] = [
        "person": [
            "id": "1",
            "name": "Luke Skywalker",
            "birthYear": "19BBY",
            "species": [
                "id": "3",
                "name": "Human",
                "classification": "mammal",
            ] as [String: any Sendable],
        ] as [String: any Sendable],
    ]

    @Test func matchesEngineV1OnFullyPopulatedItem() async throws {
        try await Self.expectMatch(rootValue: Self.fullPerson)
    }

    @Test func matchesEngineV1WhenNullableLeavesAreAbsent() async throws {
        try await Self.expectMatch(rootValue: [
            "person": [
                "id": "1",
                "name": "Leia Organa",
                // birthYear absent -> null
                "species": [
                    "id": "3",
                    "name": "Human",
                    // classification absent -> null
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ])
    }

    @Test func matchesEngineV1WhenNullableObjectIsAbsent() async throws {
        try await Self.expectMatch(rootValue: [
            "person": [
                "id": "1",
                "name": "R2-D2",
                "birthYear": "33BBY",
                // species absent -> null object
            ] as [String: any Sendable],
        ])
    }

    @Test func matchesEngineV1WhenTopLevelNullableObjectIsAbsent() async throws {
        // No "person" key -> resolver returns nil -> data.person is null with no error.
        try await Self.expectMatch(rootValue: [:])
    }

    @Test func matchesEngineV1OnNonNullNullError() async throws {
        // name is String! but absent -> non-null error nulls the (nullable) person.
        try await Self.expectMatch(rootValue: [
            "person": [
                "id": "1",
                // name absent -> "Cannot return null for non-nullable field Person.name."
                "birthYear": "19BBY",
            ] as [String: any Sendable],
        ])
    }

    static let peopleSource: [String: any Sendable] = [
        "people": [
            [
                "id": "1",
                "name": "Luke Skywalker",
                "birthYear": "19BBY",
                "species": [
                    "id": "3", "name": "Human", "classification": "mammal",
                ] as [String: any Sendable],
            ] as [String: any Sendable],
            [
                "id": "2",
                "name": "C-3PO",
                // birthYear absent -> null
                "species": [
                    "id": "4", "name": "Droid",
                    // classification absent -> null
                ] as [String: any Sendable],
            ] as [String: any Sendable],
        ] as [[String: any Sendable]],
    ]

    @Test func matchesEngineV1OnPopulatedList() async throws {
        try await Self.expectMatch(rootValue: Self.peopleSource, query: Self.listQuery)
    }

    @Test func matchesEngineV1OnEmptyList() async throws {
        try await Self.expectMatch(
            rootValue: ["people": [[String: any Sendable]]()],
            query: Self.listQuery
        )
    }

    @Test func matchesEngineV1WhenNonNullListElementNulls() async throws {
        // A missing non-null `name` on an element errors; because the element and the list are both
        // non-null, the error propagates and nulls the entire `people` field.
        try await Self.expectMatch(
            rootValue: [
                "people": [
                    ["id": "1", "name": "Luke", "species": [String: any Sendable]()]
                        as [String: any Sendable],
                    ["id": "2" /* name absent */ ] as [String: any Sendable],
                ] as [[String: any Sendable]],
            ],
            query: Self.listQuery
        )
    }

    @Test func fallsBackForFragments() throws {
        let schema = try Self.makeSchema()
        let query = """
        query SingleItem {
          person(id: "1") { ...personFields }
        }
        fragment personFields on Person { id name }
        """
        #expect(engineV2ExecuteSingleItem(schema, query, rootValue: Self.fullPerson) == nil)
    }

    @Test func fallsBackForUnknownField() throws {
        let schema = try Self.makeSchema()
        let query = "query { person(id: \"1\") { id notAField } }"
        #expect(engineV2ExecuteSingleItem(schema, query, rootValue: Self.fullPerson) == nil)
    }

    @Test func fallsBackForMissingRequiredArgument() throws {
        let schema = try Self.makeSchema()
        let query = "query { person { id name } }"
        #expect(engineV2ExecuteSingleItem(schema, query, rootValue: Self.fullPerson) == nil)
    }

    @Test func fallsBackForMalformedDocument() throws {
        let schema = try Self.makeSchema()
        let query = "query { person(id: \"1\") { id name "
        #expect(engineV2ExecuteSingleItem(schema, query, rootValue: Self.fullPerson) == nil)
    }
}
