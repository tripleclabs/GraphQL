import GraphQLFast

struct EngineV2CompiledSchema: Sendable {
    let metadata: FastCompiledSchema
    let namedTypes: ContiguousArray<GraphQLNamedType>
    let fieldDefinitions: ContiguousArray<GraphQLFieldDefinition>
    let inputDefaults: ContiguousArray<Map?>
}

extension GraphQLSchema {
    func engineV2CompiledSchema() throws -> EngineV2CompiledSchema {
        if let cached = engineV2SchemaQueue.sync(execute: { _engineV2CompiledSchema }) {
            return cached
        }

        let compiled = try EngineV2SchemaCompiler.compile(self)
        return engineV2SchemaQueue.sync(flags: .barrier) {
            if let cached = _engineV2CompiledSchema { return cached }
            _engineV2CompiledSchema = compiled
            return compiled
        }
    }
}

@_spi(EngineV2Benchmark)
public func engineV2CompileSchema(_ schema: GraphQLSchema) throws -> FastCompiledSchema {
    try EngineV2SchemaCompiler.compile(schema).metadata
}

@_spi(EngineV2Benchmark)
public func engineV2CachedSchema(_ schema: GraphQLSchema) throws -> FastCompiledSchema {
    try schema.engineV2CompiledSchema().metadata
}

private enum EngineV2SchemaCompiler {
    static func compile(_ schema: GraphQLSchema) throws -> EngineV2CompiledSchema {
        var builder = Builder(schema: schema)
        return try builder.compile()
    }
}

private struct Builder {
    let schema: GraphQLSchema
    var names: ContiguousArray<String> = []
    var nameIDs: [String: FastSchemaNameID] = [:]
    var typeIDs: [String: FastSchemaTypeID] = [:]
    var types: ContiguousArray<FastSchemaType> = []
    var typeReferences: ContiguousArray<FastSchemaTypeReference> = []
    var fields: ContiguousArray<FastSchemaField> = []
    var inputValues: ContiguousArray<FastSchemaInputValue> = []
    var namedTypes: ContiguousArray<GraphQLNamedType> = []
    var fieldDefinitions: ContiguousArray<GraphQLFieldDefinition> = []
    var inputDefaults: ContiguousArray<Map?> = []

    mutating func compile() throws -> EngineV2CompiledSchema {
        names.reserveCapacity(schema.typeMap.count * 2)
        nameIDs.reserveCapacity(schema.typeMap.count * 2)
        typeIDs.reserveCapacity(schema.typeMap.count)
        types.reserveCapacity(schema.typeMap.count)
        namedTypes.reserveCapacity(schema.typeMap.count)

        for (index, namedType) in schema.typeMap.values.enumerated() {
            let id = FastSchemaTypeID(rawValue: try checkedID(index))
            typeIDs[namedType.name] = id
            namedTypes.append(namedType)
            types.append(FastSchemaType(
                kind: kind(of: namedType),
                name: try intern(namedType.name),
                fields: .empty,
                inputFields: .empty
            ))
        }

        for (index, namedType) in namedTypes.enumerated() {
            let typeID = FastSchemaTypeID(rawValue: UInt32(index))
            let fieldRange = try compileFields(of: namedType, parent: typeID)
            let inputFieldRange = try compileInputFields(of: namedType)
            types[index] = FastSchemaType(
                kind: kind(of: namedType),
                name: types[index].name,
                fields: fieldRange,
                inputFields: inputFieldRange
            )
        }

        let roots = FastSchemaRoots(
            query: schema.queryType.flatMap { typeIDs[$0.name] },
            mutation: schema.mutationType.flatMap { typeIDs[$0.name] },
            subscription: schema.subscriptionType.flatMap { typeIDs[$0.name] }
        )
        let metadata = FastCompiledSchema(
            names: names,
            types: types,
            typeReferences: typeReferences,
            fields: fields,
            inputValues: inputValues,
            roots: roots
        )
        return EngineV2CompiledSchema(
            metadata: metadata,
            namedTypes: namedTypes,
            fieldDefinitions: fieldDefinitions,
            inputDefaults: inputDefaults
        )
    }

    mutating func compileFields(
        of namedType: GraphQLNamedType,
        parent: FastSchemaTypeID
    ) throws -> FastArenaRange {
        let definitions: GraphQLFieldDefinitionMap
        if let object = namedType as? GraphQLObjectType {
            definitions = try object.getFields()
        } else if let interface = namedType as? GraphQLInterfaceType {
            definitions = try interface.getFields()
        } else {
            return .empty
        }

        let start = try checkedID(fields.count)
        for definition in definitions.values {
            let argumentStart = try checkedID(inputValues.count)
            for argument in definition.args {
                try appendInputValue(
                    name: argument.name,
                    type: argument.type,
                    defaultValue: argument.defaultValue,
                    isDeprecated: argument.deprecationReason != nil
                )
            }
            fields.append(FastSchemaField(
                parentType: parent,
                name: try intern(definition.name),
                type: try compileTypeReference(definition.type),
                arguments: FastArenaRange(
                    start: argumentStart,
                    count: try checkedID(definition.args.count)
                ),
                isDeprecated: definition.isDeprecated
            ))
            fieldDefinitions.append(definition)
        }
        return FastArenaRange(start: start, count: try checkedID(definitions.count))
    }

    mutating func compileInputFields(of namedType: GraphQLNamedType) throws -> FastArenaRange {
        guard let inputObject = namedType as? GraphQLInputObjectType else { return .empty }
        let definitions = try inputObject.getFields()
        let start = try checkedID(inputValues.count)
        for definition in definitions.values {
            try appendInputValue(
                name: definition.name,
                type: definition.type,
                defaultValue: definition.defaultValue,
                isDeprecated: definition.deprecationReason != nil
            )
        }
        return FastArenaRange(start: start, count: try checkedID(definitions.count))
    }

    mutating func appendInputValue(
        name: String,
        type: GraphQLInputType,
        defaultValue: Map?,
        isDeprecated: Bool
    ) throws {
        inputValues.append(FastSchemaInputValue(
            name: try intern(name),
            type: try compileTypeReference(type),
            hasDefaultValue: defaultValue != nil,
            isDeprecated: isDeprecated
        ))
        inputDefaults.append(defaultValue)
    }

    mutating func compileTypeReference(
        _ type: GraphQLType
    ) throws -> FastSchemaTypeReferenceID {
        if let nonNull = type as? GraphQLNonNull {
            return try appendWrappedType(kind: .nonNull, wrapped: nonNull.ofType)
        }
        if let list = type as? GraphQLList {
            return try appendWrappedType(kind: .list, wrapped: list.ofType)
        }
        guard let named = type as? GraphQLNamedType, let namedID = typeIDs[named.name] else {
            throw GraphQLError(message: "Engine V2 cannot resolve schema type \(type).")
        }
        let id = FastSchemaTypeReferenceID(rawValue: try checkedID(typeReferences.count))
        typeReferences.append(FastSchemaTypeReference(
            kind: .named,
            namedType: namedID,
            wrappedType: nil
        ))
        return id
    }

    mutating func appendWrappedType(
        kind: FastSchemaTypeReference.Kind,
        wrapped: GraphQLType
    ) throws -> FastSchemaTypeReferenceID {
        let wrappedID = try compileTypeReference(wrapped)
        let namedType = typeReferences[Int(wrappedID.rawValue)].namedType
        let id = FastSchemaTypeReferenceID(rawValue: try checkedID(typeReferences.count))
        typeReferences.append(FastSchemaTypeReference(
            kind: kind,
            namedType: namedType,
            wrappedType: wrappedID
        ))
        return id
    }

    mutating func intern(_ name: String) throws -> FastSchemaNameID {
        if let existing = nameIDs[name] { return existing }
        let id = FastSchemaNameID(rawValue: try checkedID(names.count))
        names.append(name)
        nameIDs[name] = id
        return id
    }

    func kind(of type: GraphQLNamedType) -> FastSchemaType.Kind {
        switch type {
        case is GraphQLScalarType: return .scalar
        case is GraphQLObjectType: return .object
        case is GraphQLInterfaceType: return .interface
        case is GraphQLUnionType: return .union
        case is GraphQLEnumType: return .enum
        case is GraphQLInputObjectType: return .inputObject
        default: preconditionFailure("Unknown GraphQL named type: \(type)")
        }
    }

    func checkedID(_ value: Int) throws -> UInt32 {
        guard let id = UInt32(exactly: value) else {
            throw GraphQLError(message: "Engine V2 schema exceeds UInt32 table capacity.")
        }
        return id
    }
}
