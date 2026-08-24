public extension GraphQLSchema {
    /// A schema containing only the root fields satisfying `keep`, plus every
    /// type reachable from them.
    ///
    /// Field definitions are rebuilt with their resolvers and subscription
    /// sources intact, so the result executes rather than merely printing.
    ///
    /// - Parameter keep: called with the root type name ("Query", "Mutation",
    ///   "Subscription") and the field name.
    /// - Throws: when no query fields match — GraphQL requires a query root —
    ///   or when the reduced schema fails validation.
    func projected(
        rootFieldsWhere keep: (String, String) -> Bool
    ) throws -> GraphQLSchema {
        let query = try reducedRoot(queryType, keep: keep)
        guard query != nil else {
            throw GraphQLError(
                message: "Projection matched no root query fields. A GraphQL schema requires a query type."
            )
        }

        let schema = try GraphQLSchema(
            query: query,
            mutation: try reducedRoot(mutationType, keep: keep),
            subscription: try reducedRoot(subscriptionType, keep: keep),
            directives: directives
        )

        let errors = try validateSchema(schema: schema)
        guard errors.isEmpty else {
            throw GraphQLErrors(errors)
        }

        return schema
    }

    /// Whether the element a directive target names still exists in this schema.
    func contains(_ target: DirectiveTarget) -> Bool {
        switch target {
        case .schema:
            return true
        case let .type(name):
            return typeMap[name] != nil
        case let .member(typeName, member):
            return containsMember(member, of: typeName)
        case let .argument(typeName, fieldName, argumentName):
            return arguments(ofField: fieldName, on: typeName)
                .contains { $0.name == argumentName }
        }
    }
}

private extension GraphQLSchema {
    func reducedRoot(
        _ root: GraphQLObjectType?,
        keep: (String, String) -> Bool
    ) throws -> GraphQLObjectType? {
        guard let root = root else {
            return nil
        }

        var fields: GraphQLFieldMap = [:]
        for (fieldName, definition) in try root.getFields() where keep(root.name, fieldName) {
            fields[fieldName] = definition.toField()
        }

        guard !fields.isEmpty else {
            return nil
        }

        return try GraphQLObjectType(
            name: root.name,
            description: root.description,
            fields: fields,
            interfaces: try root.getInterfaces(),
            isTypeOf: root.isTypeOf
        )
    }

    func containsMember(_ member: String, of typeName: String) -> Bool {
        guard let type = typeMap[typeName] else {
            return false
        }
        if let object = type as? GraphQLObjectType {
            return (try? object.getFields())?[member] != nil
        }
        if let interface = type as? GraphQLInterfaceType {
            return (try? interface.getFields())?[member] != nil
        }
        if let input = type as? GraphQLInputObjectType {
            return (try? input.getFields())?[member] != nil
        }
        if let enumType = type as? GraphQLEnumType {
            return enumType.values.contains { $0.name == member }
        }
        return false
    }

    func arguments(ofField fieldName: String, on typeName: String) -> [GraphQLArgumentDefinition] {
        if let object = typeMap[typeName] as? GraphQLObjectType {
            return (try? object.getFields())?[fieldName]?.args ?? []
        }
        if let interface = typeMap[typeName] as? GraphQLInterfaceType {
            return (try? interface.getFields())?[fieldName]?.args ?? []
        }
        return []
    }
}
