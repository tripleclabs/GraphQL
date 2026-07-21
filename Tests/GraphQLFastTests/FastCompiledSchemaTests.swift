@testable import GraphQL
import GraphQLFast
import Testing

@Suite struct FastCompiledSchemaTests {
    @Test func compilesNamedTypesFieldsArgumentsAndWrappedTypes() throws {
        let fixture = try makeSchemaFixture()
        let compiled = try fixture.schema.engineV2CompiledSchema()
        let metadata = compiled.metadata

        #expect(metadata.types.count == fixture.schema.typeMap.count)
        #expect(compiled.namedTypes.count == metadata.types.count)
        #expect(compiled.fieldDefinitions.count == metadata.fields.count)
        #expect(compiled.inputDefaults.count == metadata.inputValues.count)

        let queryID = try #require(metadata.typeID(named: "Query"))
        let personID = try #require(metadata.typeID(named: "Person"))
        #expect(metadata.roots.query == queryID)
        #expect(metadata.roots.mutation == nil)
        #expect(metadata.roots.subscription == nil)
        #expect(metadata.types[Int(queryID.rawValue)].kind == .object)
        #expect(metadata.types[Int(try #require(metadata.typeID(named: "Node")).rawValue)].kind == .interface)
        #expect(metadata.types[Int(try #require(metadata.typeID(named: "SearchResult")).rawValue)].kind == .union)
        #expect(metadata.types[Int(try #require(metadata.typeID(named: "Episode")).rawValue)].kind == .enum)
        #expect(metadata.types[Int(try #require(metadata.typeID(named: "PersonFilter")).rawValue)].kind == .inputObject)

        let personFieldID = try #require(metadata.fieldID(on: queryID, named: "person"))
        let personField = metadata.fields[Int(personFieldID.rawValue)]
        #expect(personField.parentType == queryID)
        #expect(metadata.name(personField.name) == "person")
        #expect(personField.arguments.count == 1)
        #expect(metadata.typeReferences[Int(personField.type.rawValue)].namedType == personID)

        let friendsFieldID = try #require(metadata.fieldID(on: personID, named: "friends"))
        let friendsField = metadata.fields[Int(friendsFieldID.rawValue)]
        let outerNonNull = metadata.typeReferences[Int(friendsField.type.rawValue)]
        let list = metadata.typeReferences[Int(try #require(outerNonNull.wrappedType).rawValue)]
        let innerNonNull = metadata.typeReferences[Int(try #require(list.wrappedType).rawValue)]
        let named = metadata.typeReferences[Int(try #require(innerNonNull.wrappedType).rawValue)]
        #expect(outerNonNull.kind == .nonNull)
        #expect(list.kind == .list)
        #expect(innerNonNull.kind == .nonNull)
        #expect(named.kind == .named)
        #expect(named.namedType == personID)

        let searchFieldID = try #require(metadata.fieldID(on: queryID, named: "search"))
        let searchField = metadata.fields[Int(searchFieldID.rawValue)]
        let filter = metadata.inputValues[Int(searchField.arguments.start)]
        #expect(metadata.name(filter.name) == "filter")
        #expect(filter.hasDefaultValue)
        #expect(compiled.inputDefaults[Int(searchField.arguments.start)] == Map.dictionary([:]))
    }

    @Test func cachesOneImmutableCompiledView() throws {
        let fixture = try makeSchemaFixture()
        let first = try fixture.schema.engineV2CompiledSchema()
        let second = try fixture.schema.engineV2CompiledSchema()

        let firstAddress = first.metadata.types.withUnsafeBufferPointer { $0.baseAddress }
        let secondAddress = second.metadata.types.withUnsafeBufferPointer { $0.baseAddress }
        #expect(firstAddress == secondAddress)
    }

    @Test func compiledLookupsAreSafeForConcurrentReads() async throws {
        let fixture = try makeSchemaFixture()
        let metadata = try fixture.schema.engineV2CompiledSchema().metadata
        let queryID = try #require(metadata.roots.query)

        let successes = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for _ in 0 ..< 32 {
                group.addTask {
                    var count = 0
                    for _ in 0 ..< 1_000 {
                        if metadata.fieldID(on: queryID, named: "person") != nil { count += 1 }
                    }
                    return count
                }
            }
            var total = 0
            for await count in group { total += count }
            return total
        }
        #expect(successes == 32_000)
    }
}

private struct SchemaFixture {
    let schema: GraphQLSchema
}

private func makeSchemaFixture() throws -> SchemaFixture {
    let episode = try GraphQLEnumType(
        name: "Episode",
        values: ["NEWHOPE": GraphQLEnumValue(value: "NEWHOPE")]
    )
    let filter = try GraphQLInputObjectType(
        name: "PersonFilter",
        fields: [
            "episode": InputObjectField(type: episode),
            "name": InputObjectField(type: GraphQLString, defaultValue: "Luke"),
        ]
    )
    let node = try GraphQLInterfaceType(
        name: "Node",
        fields: ["id": GraphQLField(type: GraphQLNonNull(GraphQLID))]
    )
    var person: GraphQLObjectType!
    person = try GraphQLObjectType(
        name: "Person",
        fields: {
            [
                "id": GraphQLField(type: GraphQLNonNull(GraphQLID)),
                "name": GraphQLField(type: GraphQLString),
                "friends": GraphQLField(
                    type: GraphQLNonNull(GraphQLList(GraphQLNonNull(person)))
                ),
            ]
        },
        interfaces: { [node] }
    )
    let searchResult = try GraphQLUnionType(name: "SearchResult", types: [person])
    let query = try GraphQLObjectType(
        name: "Query",
        fields: [
            "person": GraphQLField(
                type: person,
                args: ["id": GraphQLArgument(type: GraphQLNonNull(GraphQLID))]
            ),
            "search": GraphQLField(
                type: GraphQLList(searchResult),
                args: [
                    "filter": GraphQLArgument(
                        type: filter,
                        defaultValue: Map.dictionary([:])
                    ),
                ]
            ),
        ]
    )
    return try SchemaFixture(schema: GraphQLSchema(query: query))
}
