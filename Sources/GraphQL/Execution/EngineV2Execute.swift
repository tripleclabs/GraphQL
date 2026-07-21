import GraphQLFast
import OrderedCollections

/// Engine V2 narrow vertical slice for the benchmark's `single_item` shape.
///
/// This path is deliberately restricted: it fuses parsing, name-to-numeric resolution, structural
/// validation, and synchronous execution over the compiled schema without constructing the Engine
/// V1 AST, validation visitor graph, `GraphQLResolveInfo`, argument maps, or response paths on the
/// hot path. Any construct it cannot prove equivalent to Engine V1 makes the planner return `nil`
/// so the caller falls back to Engine V1 before a single resolver runs.
///
/// It is not yet wired into the public `graphql(...)` entry point and is reachable only through the
/// Engine V2 benchmark/differential SPI. Argument *value* coercion validation is intentionally not
/// implemented here; the fast path must not be enabled for untrusted documents until it is.
enum EngineV2Execute {
    /// Resolver forms the slice can execute without observing args/info.
    enum PlanResolver {
        case sourceOnly(GraphQLFieldFastResolve)
        case defaultKeyed
    }

    /// Completion shape for one planned field. Lists and abstract types are deliberately excluded
    /// and force a fallback during planning.
    indirect enum PlanCompletion {
        case leaf(GraphQLLeafType, nonNull: Bool)
        case object(GraphQLObjectType, nonNull: Bool, children: [PlanField])
    }

    struct PlanField {
        let responseKey: String
        let fieldName: String
        let parentTypeName: String
        let resolver: PlanResolver
        let completion: PlanCompletion
    }

    /// Executes the request through the fast path, or returns `nil` when the document is not
    /// eligible and Engine V1 must handle it.
    static func run(
        schema: GraphQLSchema,
        request: String,
        rootValue: any Sendable,
        variableValues: [String: Map],
        operationName: String?
    ) -> GraphQLResult? {
        // The slice does not yet coerce variables.
        guard variableValues.isEmpty else { return nil }
        guard let compiled = try? schema.engineV2CompiledSchema() else { return nil }
        guard let document = try? FastParser.parse(request) else { return nil }

        // Structural eligibility: exactly one query operation, no fragments, no operation-level
        // variables or directives.
        guard document.fragments.isEmpty, document.operations.count == 1 else { return nil }
        let operation = document.operations[0]
        guard operation.kind == .query else { return nil }
        guard operation.variableDefinitions.count == 0, operation.directives.count == 0 else {
            return nil
        }
        if let operationName {
            guard let nameRange = operation.name, document.text(nameRange) == operationName
            else { return nil }
        }

        guard let queryTypeID = compiled.metadata.roots.query else { return nil }
        guard compiled.namedTypes[Int(queryTypeID.rawValue)] is GraphQLObjectType else { return nil }

        var planner = Planner(document: document, compiled: compiled)
        guard let plan = planner.planSelectionSet(
            operation.selectionSet,
            parentType: queryTypeID
        ) else { return nil }

        var errors: [GraphQLError] = []
        let data: OrderedDictionary<String, Map>
        do {
            data = try execute(fields: plan, source: rootValue, errors: &errors)
        } catch let error as GraphQLError {
            errors.append(error)
            return GraphQLResult(data: .null, errors: errors)
        } catch {
            errors.append(GraphQLError(error))
            return GraphQLResult(data: .null, errors: errors)
        }
        return GraphQLResult(data: .dictionary(data), errors: errors)
    }

    // MARK: - Planning

    private struct Planner {
        let document: FastDocument
        let compiled: EngineV2CompiledSchema

        func planSelectionSet(
            _ selectionSetIndex: UInt32,
            parentType: FastSchemaTypeID
        ) -> [PlanField]? {
            let set = document.selectionSets[Int(selectionSetIndex)]
            guard set.selectionCount > 0 else { return nil }

            var fields: [PlanField] = []
            fields.reserveCapacity(Int(set.selectionCount))
            var seenKeys = Set<String>()

            var cursor = set.firstSelection
            while let index = cursor {
                let selection = document.selections[Int(index)]
                cursor = selection.nextSibling

                // Only plain field selections are supported; fragments/inline fragments fall back.
                guard selection.kind == .field else { return nil }
                guard selection.directives.count == 0 else { return nil }
                guard let nameRange = selection.name else { return nil }

                let fieldName = document.text(nameRange)
                let responseKey = selection.alias.map { document.text($0) } ?? fieldName
                // Duplicate response keys require Engine V1 field merging.
                guard seenKeys.insert(responseKey).inserted else { return nil }

                guard let fieldID = compiled.metadata.fieldID(on: parentType, named: fieldName)
                else { return nil }
                let schemaField = compiled.metadata.fields[Int(fieldID.rawValue)]

                guard validateArguments(selection.arguments, schemaField: schemaField) else {
                    return nil
                }

                guard let resolver = planResolver(fieldID: fieldID) else { return nil }

                let parentTypeName = compiled.metadata.name(
                    compiled.metadata.types[Int(parentType.rawValue)].name
                )
                guard let completion = planCompletion(
                    typeReference: schemaField.type,
                    childSelectionSet: selection.selectionSet
                ) else { return nil }

                fields.append(PlanField(
                    responseKey: responseKey,
                    fieldName: fieldName,
                    parentTypeName: parentTypeName,
                    resolver: resolver,
                    completion: completion
                ))
            }
            return fields
        }

        private func planResolver(fieldID: FastSchemaFieldID) -> PlanResolver? {
            switch compiled.fieldResolvers[Int(fieldID.rawValue)] {
            case let .sourceOnly(thunk):
                return .sourceOnly(thunk)
            case .synchronous:
                // Only the default (key-path) resolver is executable without args/info. A custom
                // synchronous resolver could observe them, so fall back.
                let definition = compiled.fieldDefinitions[Int(fieldID.rawValue)]
                if definition.fastResolve == nil,
                   definition.synchronousResolve == nil,
                   definition.resolve == nil
                {
                    return .defaultKeyed
                }
                return nil
            case .asynchronous:
                return nil
            }
        }

        private func planCompletion(
            typeReference: FastSchemaTypeReferenceID,
            childSelectionSet: UInt32?
        ) -> PlanCompletion? {
            var reference = compiled.metadata.typeReferences[Int(typeReference.rawValue)]
            var nonNull = false
            if reference.kind == .nonNull {
                nonNull = true
                guard let wrapped = reference.wrappedType else { return nil }
                reference = compiled.metadata.typeReferences[Int(wrapped.rawValue)]
            }
            // Lists and additional wrappers are deferred to the list_items slice.
            guard reference.kind == .named else { return nil }

            let namedType = compiled.namedTypes[Int(reference.namedType.rawValue)]
            if let leaf = namedType as? GraphQLLeafType {
                guard childSelectionSet == nil else { return nil }
                return .leaf(leaf, nonNull: nonNull)
            }
            if let object = namedType as? GraphQLObjectType {
                // Runtime type disambiguation is out of slice scope.
                guard object.isTypeOf == nil else { return nil }
                guard let childSelectionSet else { return nil }
                guard let children = planSelectionSet(
                    childSelectionSet,
                    parentType: reference.namedType
                ) else { return nil }
                return .object(object, nonNull: nonNull, children: children)
            }
            // Unions, interfaces, and input objects fall back.
            return nil
        }

        /// Conservative structural argument validation: every provided argument must be declared,
        /// no argument value may be a variable, and every required argument must be present. Value
        /// coercion is not performed, so this must not gate untrusted input.
        private func validateArguments(
            _ argumentRange: FastArenaRange,
            schemaField: FastSchemaField
        ) -> Bool {
            let declaredStart = Int(schemaField.arguments.start)
            let declaredEnd = declaredStart + Int(schemaField.arguments.count)

            var providedNames = Set<String>()
            let argStart = Int(argumentRange.start)
            let argEnd = argStart + Int(argumentRange.count)
            for i in argStart ..< argEnd {
                let argument = document.arguments[i]
                let value = document.values[Int(argument.value)]
                if value.kind == .variable { return false }
                let name = document.text(argument.name)

                var matched = false
                for d in declaredStart ..< declaredEnd
                    where compiled.metadata.name(compiled.metadata.inputValues[d].name) == name
                {
                    matched = true
                    break
                }
                guard matched else { return false }
                providedNames.insert(name)
            }

            for d in declaredStart ..< declaredEnd {
                let input = compiled.metadata.inputValues[d]
                guard !input.hasDefaultValue else { continue }
                let reference = compiled.metadata.typeReferences[Int(input.type.rawValue)]
                guard reference.kind == .nonNull else { continue }
                let name = compiled.metadata.name(input.name)
                if !providedNames.contains(name) { return false }
            }
            return true
        }
    }

    // MARK: - Execution

    private static func execute(
        fields: [PlanField],
        source: any Sendable,
        errors: inout [GraphQLError]
    ) throws -> OrderedDictionary<String, Map> {
        var results = OrderedDictionary<String, Map>()
        results.reserveCapacity(fields.count)
        for field in fields {
            let resolved = try resolve(field: field, source: source)
            let completed = try completeCatchingError(
                field: field,
                value: resolved,
                errors: &errors
            )
            results[field.responseKey] = completed ?? .null
        }
        return results
    }

    private static func resolve(field: PlanField, source: any Sendable) throws -> (any Sendable)? {
        switch field.resolver {
        case let .sourceOnly(thunk):
            return try thunk(source)
        case .defaultKeyed:
            return extractKey(from: source, name: field.fieldName)
        }
    }

    /// Mirrors Engine V1's non-introspection default resolution: read the field's key directly
    /// from the source container.
    private static func extractKey(from source: any Sendable, name: String) -> (any Sendable)? {
        guard let source = unwrap(source) else { return nil }
        if let subscriptable = source as? KeySubscriptable {
            return subscriptable[name]
        }
        if let subscriptable = source as? [String: any Sendable] {
            return subscriptable[name]
        }
        if let subscriptable = source as? OrderedDictionary<String, any Sendable> {
            return subscriptable[name]
        }
        return Mirror(reflecting: source).getValue(named: name)
    }

    private static func completeCatchingError(
        field: PlanField,
        value: (any Sendable)?,
        errors: inout [GraphQLError]
    ) throws -> Map? {
        if field.completion.isNonNull {
            // Errors in non-null positions propagate to null the parent.
            return try complete(field: field, value: value, errors: &errors)
        }
        do {
            return try complete(field: field, value: value, errors: &errors)
        } catch let error as GraphQLError {
            errors.append(error)
            return nil
        }
    }

    private static func complete(
        field: PlanField,
        value: (any Sendable)?,
        errors: inout [GraphQLError]
    ) throws -> Map? {
        switch field.completion {
        case let .leaf(leaf, nonNull):
            guard let value, let unwrapped = unwrap(value) else {
                if nonNull { throw nonNullError(field) }
                return nil
            }
            return try leaf.serialize(value: unwrapped)
        case let .object(_, nonNull, children):
            guard let value, let unwrapped = unwrap(value) else {
                if nonNull { throw nonNullError(field) }
                return nil
            }
            return .dictionary(try execute(fields: children, source: unwrapped, errors: &errors))
        }
    }

    private static func nonNullError(_ field: PlanField) -> GraphQLError {
        GraphQLError(
            message: "Cannot return null for non-nullable field \(field.parentTypeName).\(field.fieldName)."
        )
    }
}

private extension EngineV2Execute.PlanCompletion {
    var isNonNull: Bool {
        switch self {
        case let .leaf(_, nonNull): return nonNull
        case let .object(_, nonNull, _): return nonNull
        }
    }
}

@_spi(EngineV2Benchmark)
public func engineV2ExecuteSingleItem(
    _ schema: GraphQLSchema,
    _ request: String,
    rootValue: any Sendable = ()
) -> GraphQLResult? {
    EngineV2Execute.run(
        schema: schema,
        request: request,
        rootValue: rootValue,
        variableValues: [:],
        operationName: nil
    )
}
