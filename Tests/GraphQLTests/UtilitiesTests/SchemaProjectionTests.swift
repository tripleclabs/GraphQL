@testable import GraphQL
import Testing

private func sampleSchema() throws -> GraphQLSchema {
    let billingAccount = try GraphQLObjectType(
        name: "BillingAccount",
        fields: ["id": GraphQLField(type: GraphQLString)]
    )
    let product = try GraphQLObjectType(
        name: "Product",
        fields: ["sku": GraphQLField(type: GraphQLString)]
    )
    let query = try GraphQLObjectType(
        name: "Query",
        fields: [
            "billing": GraphQLField(
                type: billingAccount,
                resolve: { _, _, _, _ in ["id": "acct-1"] }
            ),
            "search": GraphQLField(type: product),
        ]
    )
    let mutation = try GraphQLObjectType(
        name: "Mutation",
        fields: [
            "pay": GraphQLField(type: GraphQLString),
            "reindex": GraphQLField(type: GraphQLString),
        ]
    )
    return try GraphQLSchema(query: query, mutation: mutation)
}

@Suite struct SchemaProjectionTests {
    @Test func keepsOnlyMatchingRootFields() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        let queryFields = try #require(projected.queryType).getFields()
        #expect(try queryFields.keys.sorted() == ["billing"])
    }

    @Test func includesTypesReachableFromKeptFields() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        #expect(projected.typeMap["BillingAccount"] != nil)
    }

    @Test func excludesTypesReachableOnlyFromDroppedFields() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        #expect(projected.typeMap["Product"] == nil)
    }

    @Test func filtersEachRootTypeIndependently() throws {
        let projected = try sampleSchema().projected { rootType, field in
            (rootType == "Query" && field == "billing") ||
                (rootType == "Mutation" && field == "pay")
        }
        let mutationFields = try #require(projected.mutationType).getFields()
        #expect(try mutationFields.keys.sorted() == ["pay"])
    }

    @Test func omitsRootTypeWithNoSurvivingFields() throws {
        let projected = try sampleSchema().projected { rootType, field in
            rootType == "Query" && field == "billing"
        }
        #expect(projected.mutationType == nil)
    }

    @Test func throwsWhenNoQueryFieldsMatch() throws {
        #expect(throws: (any Error).self) {
            try sampleSchema().projected { rootType, _ in rootType == "Mutation" }
        }
    }

    @Test func projectionStillExecutes() async throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        let result = try await graphql(schema: projected, request: "{ billing { id } }")
        #expect(result.data?["billing"]["id"].string == "acct-1")
        #expect(result.errors.isEmpty)
    }

    @Test func projectionPreservesSubscriptionSources() throws {
        // toField() carries `subscribe` as well as `resolve`; without it a
        // projected subscription root would print but never fire.
        let subscription = try GraphQLObjectType(
            name: "Subscription",
            fields: [
                "ticks": GraphQLField(
                    type: GraphQLString,
                    resolve: { source, _, _, _ in source },
                    subscribe: { _, _, _, _ in AsyncStream<String> { $0.finish() } }
                ),
                "noise": GraphQLField(type: GraphQLString),
            ]
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: ["billing": GraphQLField(type: GraphQLString)]
        )
        let schema = try GraphQLSchema(query: query, subscription: subscription)

        let projected = try schema.projected { rootType, field in
            rootType == "Query" || field == "ticks"
        }

        let fields = try #require(projected.subscriptionType).getFields()
        #expect(try fields.keys.sorted() == ["ticks"])
        #expect(try #require(fields["ticks"]).subscribe != nil)
    }

    @Test func containsReportsSurvivingElements() throws {
        let projected = try sampleSchema().projected { _, field in field == "billing" }
        #expect(projected.contains(.type("BillingAccount")))
        #expect(!projected.contains(.type("Product")))
        #expect(projected.contains(.member(type: "Query", member: "billing")))
        #expect(!projected.contains(.member(type: "Query", member: "search")))
    }
}

private func interfaceSchema() throws -> GraphQLSchema {
    let node = try GraphQLInterfaceType(
        name: "Node",
        fields: ["id": GraphQLField(type: GraphQLString)]
    )
    let account = try GraphQLObjectType(
        name: "Account",
        fields: ["id": GraphQLField(type: GraphQLString)],
        interfaces: [node],
        isTypeOf: { source, _ in
            (source as? [String: String])?["kind"] == "account"
        }
    )
    let query = try GraphQLObjectType(
        name: "Query",
        fields: [
            "node": GraphQLField(
                type: node,
                resolve: { _, _, _, _ in ["id": "n-1", "kind": "account"] }
            ),
        ]
    )
    return try GraphQLSchema(query: query, types: [account])
}

@Suite struct SchemaProjectionInterfaceTests {
    @Test func includesInterfaceImplementations() throws {
        let projected = try interfaceSchema().projected { _, field in field == "node" }
        #expect(projected.typeMap["Node"] != nil)
        #expect(projected.typeMap["Account"] != nil)
    }

    @Test func projectionResolvesConcreteTypeAtRuntime() async throws {
        let projected = try interfaceSchema().projected { _, field in field == "node" }
        let result = try await graphql(
            schema: projected,
            request: "{ node { __typename id } }"
        )
        #expect(result.errors.isEmpty)
        #expect(result.data?["node"]["__typename"].string == "Account")
    }
}
