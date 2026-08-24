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

/// Completeness only needs implementations for interfaces something in the view
/// can actually *return* — the runtime resolves a concrete type only then. An
/// interface present merely because a retained object declares it can never be
/// returned, so its other implementors are dead weight.
@Suite struct SchemaProjectionInterfaceScopeTests {
    private func siblingSchema() throws -> GraphQLSchema {
        let iface = try GraphQLInterfaceType(
            name: "Iface",
            fields: { ["id": GraphQLField(type: GraphQLString)] }
        )
        var siblings: [GraphQLObjectType] = []
        for i in 0 ..< 5 {
            siblings.append(try GraphQLObjectType(
                name: "Sibling\(i)",
                fields: { ["id": GraphQLField(type: GraphQLString)] },
                interfaces: { [iface] },
                isTypeOf: { src, _ in (src as? [String: String])?["k"] == "s\(i)" }
            ))
        }
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "concrete": GraphQLField(
                    type: siblings[0],
                    resolve: { _, _, _, _ in ["k": "s0", "id": "1"] }
                ),
                "abstract": GraphQLField(
                    type: iface,
                    resolve: { _, _, _, _ in ["k": "s0", "id": "1"] }
                ),
            ]
        )
        return try GraphQLSchema(query: query, types: siblings)
    }

    private func userTypes(_ schema: GraphQLSchema) -> [String] {
        schema.typeMap.keys
            .filter { !$0.hasPrefix("__") && !["String", "Boolean", "Query"].contains($0) }
            .sorted()
    }

    @Test func concreteReturnDoesNotPullInInterfaceSiblings() throws {
        let projected = try siblingSchema().projected { _, field in field == "concrete" }
        // Sibling0 declares Iface, so Iface comes along — but nothing here can
        // return Iface, so Sibling1...4 are not needed.
        #expect(userTypes(projected) == ["Iface", "Sibling0"])
    }

    @Test func abstractReturnStillPullsInAllImplementors() throws {
        let projected = try siblingSchema().projected { _, field in field == "abstract" }
        #expect(userTypes(projected) == [
            "Iface", "Sibling0", "Sibling1", "Sibling2", "Sibling3", "Sibling4",
        ])
    }

    @Test func concreteProjectionStillExecutes() async throws {
        let projected = try siblingSchema().projected { _, field in field == "concrete" }
        let result = try await graphql(schema: projected, request: "{ concrete { id } }")
        #expect(result.errors.isEmpty)
        #expect(result.data?["concrete"]["id"].string == "1")
    }

    @Test func abstractProjectionStillResolvesConcreteType() async throws {
        let projected = try siblingSchema().projected { _, field in field == "abstract" }
        let result = try await graphql(schema: projected, request: "{ abstract { __typename } }")
        #expect(result.errors.isEmpty)
        #expect(result.data?["abstract"]["__typename"].string == "Sibling0")
    }
}

@Suite struct SchemaProjectionUnionAndNestedInterfaceTests {
    @Test func unionMembersSurviveAndExecute() async throws {
        let a = try GraphQLObjectType(
            name: "A",
            fields: { ["x": GraphQLField(type: GraphQLString)] },
            isTypeOf: { src, _ in (src as? [String: String])?["k"] == "a" }
        )
        let b = try GraphQLObjectType(
            name: "B",
            fields: { ["y": GraphQLField(type: GraphQLString)] },
            isTypeOf: { src, _ in (src as? [String: String])?["k"] == "b" }
        )
        let result = try GraphQLUnionType(name: "Result", types: [a, b])
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "find": GraphQLField(type: result, resolve: { _, _, _, _ in ["k": "a", "x": "hi"] }),
                "other": GraphQLField(type: GraphQLString),
            ]
        )
        let projected = try GraphQLSchema(query: query).projected { _, f in f == "find" }
        #expect(projected.typeMap["A"] != nil)
        #expect(projected.typeMap["B"] != nil)

        let response = try await graphql(schema: projected, request: "{ find { __typename } }")
        #expect(response.errors.isEmpty)
        #expect(response.data?["find"]["__typename"].string == "A")
    }

    @Test func interfaceImplementingInterfaceSurvivesAndExecutes() async throws {
        let node = try GraphQLInterfaceType(
            name: "Node",
            fields: { ["id": GraphQLField(type: GraphQLString)] }
        )
        let resource = try GraphQLInterfaceType(
            name: "Resource",
            fields: { ["id": GraphQLField(type: GraphQLString)] },
            interfaces: { [node] }
        )
        let doc = try GraphQLObjectType(
            name: "Doc",
            fields: { ["id": GraphQLField(type: GraphQLString)] },
            interfaces: { [resource, node] },
            isTypeOf: { src, _ in (src as? [String: String])?["k"] == "doc" }
        )
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "node": GraphQLField(type: node, resolve: { _, _, _, _ in ["k": "doc", "id": "1"] }),
            ]
        )
        let schema = try GraphQLSchema(query: query, types: [doc, resource])
        let projected = try schema.projected { _, _ in true }

        #expect(projected.typeMap["Doc"] != nil)
        #expect(projected.typeMap["Resource"] != nil)

        let response = try await graphql(schema: projected, request: "{ node { __typename } }")
        #expect(response.errors.isEmpty)
        #expect(response.data?["node"]["__typename"].string == "Doc")
    }
}
