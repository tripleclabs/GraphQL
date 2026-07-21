import GraphQLFast

struct EngineV2CompiledSchema: Sendable {
    let metadata: FastCompiledSchema
    let namedTypes: ContiguousArray<GraphQLNamedType>
    let fieldDefinitions: ContiguousArray<GraphQLFieldDefinition>
    let fieldResolvers: ContiguousArray<EngineV2FieldResolver>
    let subscriptionResolvers: ContiguousArray<GraphQLFieldResolve>
    let inputDefaults: ContiguousArray<Map?>
    let enumValueDefinitions: ContiguousArray<GraphQLEnumValueDefinition>
    let directiveDefinitions: ContiguousArray<GraphQLDirective>
}

enum EngineV2FieldResolver: Sendable {
    case sourceOnly(GraphQLFieldFastResolve)
    case synchronous(GraphQLFieldResolveInput)
    case asynchronous(GraphQLFieldResolve)
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
    var typeMembers: ContiguousArray<FastSchemaTypeID> = []
    var enumValues: ContiguousArray<FastSchemaEnumValue> = []
    var directives: ContiguousArray<FastSchemaDirective> = []
    var namedTypes: ContiguousArray<GraphQLNamedType> = []
    var fieldDefinitions: ContiguousArray<GraphQLFieldDefinition> = []
    var fieldResolvers: ContiguousArray<EngineV2FieldResolver> = []
    var subscriptionResolvers: ContiguousArray<GraphQLFieldResolve> = []
    var inputDefaults: ContiguousArray<Map?> = []
    var enumValueDefinitions: ContiguousArray<GraphQLEnumValueDefinition> = []

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
                inputFields: .empty,
                interfaces: .empty,
                possibleTypes: .empty,
                enumValues: .empty
            ))
        }

        for (index, namedType) in namedTypes.enumerated() {
            let typeID = FastSchemaTypeID(rawValue: UInt32(index))
            let fieldRange = try compileFields(of: namedType, parent: typeID)
            let inputFieldRange = try compileInputFields(of: namedType)
            let interfaceRange = try compileInterfaces(of: namedType)
            let possibleTypeRange = try compilePossibleTypes(of: namedType)
            let enumValueRange = try compileEnumValues(of: namedType)
            types[index] = FastSchemaType(
                kind: kind(of: namedType),
                name: types[index].name,
                fields: fieldRange,
                inputFields: inputFieldRange,
                interfaces: interfaceRange,
                possibleTypes: possibleTypeRange,
                enumValues: enumValueRange
            )
        }

        try compileDirectives()

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
            typeMembers: typeMembers,
            enumValues: enumValues,
            directives: directives,
            roots: roots
        )
        return EngineV2CompiledSchema(
            metadata: metadata,
            namedTypes: namedTypes,
            fieldDefinitions: fieldDefinitions,
            fieldResolvers: fieldResolvers,
            subscriptionResolvers: subscriptionResolvers,
            inputDefaults: inputDefaults,
            enumValueDefinitions: enumValueDefinitions,
            directiveDefinitions: ContiguousArray(schema.directives)
        )
    }

    mutating func compileInterfaces(of namedType: GraphQLNamedType) throws -> FastArenaRange {
        let interfaces: [GraphQLInterfaceType]
        if let object = namedType as? GraphQLObjectType {
            interfaces = try object.getInterfaces()
        } else if let interface = namedType as? GraphQLInterfaceType {
            interfaces = try interface.getInterfaces()
        } else {
            return .empty
        }
        return try appendTypeMembers(interfaces)
    }

    mutating func compilePossibleTypes(of namedType: GraphQLNamedType) throws -> FastArenaRange {
        if let union = namedType as? GraphQLUnionType {
            return try appendTypeMembers(try union.getTypes())
        }
        if let interface = namedType as? GraphQLInterfaceType {
            return try appendTypeMembers(schema.getImplementations(interfaceType: interface).objects)
        }
        return .empty
    }

    mutating func appendTypeMembers<T: Sequence>(
        _ members: T
    ) throws -> FastArenaRange where T.Element: GraphQLNamedType {
        let start = try checkedID(typeMembers.count)
        var count: UInt32 = 0
        for member in members {
            guard let id = typeIDs[member.name] else {
                throw GraphQLError(message: "Engine V2 cannot resolve schema type \(member.name).")
            }
            typeMembers.append(id)
            count += 1
        }
        return FastArenaRange(start: start, count: count)
    }

    mutating func compileEnumValues(of namedType: GraphQLNamedType) throws -> FastArenaRange {
        guard let enumType = namedType as? GraphQLEnumType else { return .empty }
        let start = try checkedID(enumValues.count)
        for value in enumType.values {
            enumValues.append(FastSchemaEnumValue(
                name: try intern(value.name),
                isDeprecated: value.isDeprecated
            ))
            enumValueDefinitions.append(value)
        }
        return FastArenaRange(start: start, count: try checkedID(enumType.values.count))
    }

    mutating func compileDirectives() throws {
        directives.reserveCapacity(schema.directives.count)
        for directive in schema.directives {
            let argumentStart = try checkedID(inputValues.count)
            for argument in directive.args {
                try appendInputValue(
                    name: argument.name,
                    type: argument.type,
                    defaultValue: argument.defaultValue,
                    isDeprecated: argument.deprecationReason != nil
                )
            }
            directives.append(FastSchemaDirective(
                name: try intern(directive.name),
                arguments: FastArenaRange(
                    start: argumentStart,
                    count: try checkedID(directive.args.count)
                ),
                locations: directive.locations.reduce(into: FastDirectiveLocations()) {
                    $0.insert(fastLocation($1))
                },
                isRepeatable: directive.isRepeatable
            ))
        }
    }

    func fastLocation(_ location: DirectiveLocation) -> FastDirectiveLocations {
        switch location {
        case .query: return .query
        case .mutation: return .mutation
        case .subscription: return .subscription
        case .field: return .field
        case .fragmentDefinition: return .fragmentDefinition
        case .fragmentSpread: return .fragmentSpread
        case .fragmentVariableDefinition: return .fragmentVariableDefinition
        case .inlineFragment: return .inlineFragment
        case .variableDefinition: return .variableDefinition
        case .schema: return .schema
        case .scalar: return .scalar
        case .object: return .object
        case .fieldDefinition: return .fieldDefinition
        case .argumentDefinition: return .argumentDefinition
        case .interface: return .interface
        case .union: return .union
        case .enum: return .enum
        case .enumValue: return .enumValue
        case .inputObject: return .inputObject
        case .inputFieldDefinition: return .inputFieldDefinition
        }
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
            let resolver = compileResolver(definition)
            fields.append(FastSchemaField(
                parentType: parent,
                name: try intern(definition.name),
                type: try compileTypeReference(definition.type),
                arguments: FastArenaRange(
                    start: argumentStart,
                    count: try checkedID(definition.args.count)
                ),
                isDeprecated: definition.isDeprecated,
                resolverKind: resolver.kind,
                resolverIsComplete: definition.fastResolveIsComplete && definition.fastResolve != nil,
                hasCustomSubscribe: definition.subscribe != nil
            ))
            fieldDefinitions.append(definition)
            fieldResolvers.append(resolver.thunk)
            subscriptionResolvers.append(compileSubscriptionResolver(definition))
        }
        return FastArenaRange(start: start, count: try checkedID(definitions.count))
    }

    func compileSubscriptionResolver(_ definition: GraphQLFieldDefinition) -> GraphQLFieldResolve {
        if let subscribe = definition.subscribe { return subscribe }
        return { source, args, context, info in
            try defaultResolve(source: source, args: args, context: context, info: info)
        }
    }

    func compileResolver(
        _ definition: GraphQLFieldDefinition
    ) -> (kind: FastSchemaFieldResolverKind, thunk: EngineV2FieldResolver) {
        if let fastResolve = definition.fastResolve {
            return (.sourceOnly, .sourceOnly(fastResolve))
        }
        if let synchronousResolve = definition.synchronousResolve {
            return (.synchronous, .synchronous(synchronousResolve))
        }
        if let resolve = definition.resolve {
            return (.asynchronous, .asynchronous(resolve))
        }
        return (.synchronous, .synchronous(defaultResolve))
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
