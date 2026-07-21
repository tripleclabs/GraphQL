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

    /// Completion shape for one planned field, mirroring the field's wrapped output type. Abstract
    /// and input types are excluded and force a fallback during planning.
    indirect enum PlanCompletion {
        /// `stringCoercible` marks `String`/`ID`, whose serialization of a Swift `String` source is
        /// exactly `.string(value)`, enabling a fast path that skips existential scalar dispatch.
        case leaf(GraphQLLeafType, stringCoercible: Bool)
        case object(GraphQLObjectType, children: [PlanField])
        case list(PlanCompletion)
        case nonNull(PlanCompletion)

        var isNonNull: Bool {
            if case .nonNull = self { return true }
            return false
        }
    }

    struct PlanField {
        let responseKey: String
        let fieldName: String
        let parentTypeName: String
        let resolver: PlanResolver
        let completion: PlanCompletion
    }

    /// A fully compiled, self-contained execution plan. It captures resolver thunks, completion
    /// shapes, and response keys, so execution needs neither the document nor the compiled schema.
    struct Plan {
        let fields: [PlanField]
    }

    /// Compiles the request into a plan outcome. Parsing, name-to-numeric resolution, and structural
    /// validation all happen here in one pass. `.fallback` means Engine V1 must handle the document.
    static func compilePlan(
        schema: GraphQLSchema,
        request: String,
        variableValues: [String: Map],
        operationName: String?
    ) -> PlanOutcome {
        // The slice does not yet coerce variables.
        guard variableValues.isEmpty else { return .fallback }
        guard let compiled = try? schema.engineV2CompiledSchema() else { return .fallback }
        guard let document = try? FastParser.parse(request) else { return .fallback }

        // Structural eligibility: exactly one query operation, no fragments, no operation-level
        // variables or directives.
        guard document.fragments.isEmpty, document.operations.count == 1 else { return .fallback }
        let operation = document.operations[0]
        guard operation.kind == .query else { return .fallback }
        guard operation.variableDefinitions.count == 0, operation.directives.count == 0 else {
            return .fallback
        }
        if let operationName {
            guard let nameRange = operation.name, document.text(nameRange) == operationName
            else { return .fallback }
        }

        guard let queryTypeID = compiled.metadata.roots.query else { return .fallback }
        guard compiled.namedTypes[Int(queryTypeID.rawValue)] is GraphQLObjectType
        else { return .fallback }

        let planner = Planner(document: document, compiled: compiled)
        guard let fields = planner.planSelectionSet(
            operation.selectionSet,
            parentType: queryTypeID
        ) else { return .fallback }

        // Unknown fields dominate: if any were found, the document is invalid, so no execution plan
        // is produced. The remainder passed every structural check, so Engine V1 would report only
        // these `FieldsOnCorrectType` errors — which are reconstructed here with exact parity.
        if !planner.undefinedFields.isEmpty {
            return .validationErrors(planner.undefinedFields.map {
                undefinedFieldError($0, schema: schema, source: request)
            })
        }
        return .plan(Plan(fields: fields))
    }

    /// Reconstructs Engine V1's `FieldsOnCorrectType` error for an unknown field, reusing V1's own
    /// message and suggestion helpers and the shared byte-position-to-`SourceLocation` conversion so
    /// the message, "Did you mean" suggestions, and source location match exactly.
    private static func undefinedFieldError(
        _ field: UndefinedField,
        schema: GraphQLSchema,
        source: String
    ) -> GraphQLError {
        let suggestedTypeNames = (try? getSuggestedTypeNames(
            schema: schema,
            type: field.parentType,
            fieldName: field.fieldName
        )) ?? []
        let suggestedFieldNames = suggestedTypeNames.isEmpty ? getSuggestedFieldNames(
            schema: schema,
            type: field.parentType,
            fieldName: field.fieldName
        ) : []
        let message = undefinedFieldMessage(
            fieldName: field.fieldName,
            type: field.parentTypeName,
            suggestedTypeNames: suggestedTypeNames,
            suggestedFieldNames: suggestedFieldNames
        )
        let location = fastSourceLocation(source: source, position: field.position)
        return GraphQLError(message: message, locations: [location])
    }

    /// Executes a precompiled plan against a root value and materializes the public result.
    static func execute(plan: Plan, rootValue: any Sendable) -> GraphQLResult {
        var errors: [GraphQLError] = []
        let data: OrderedDictionary<String, Map>
        do {
            data = try execute(fields: plan.fields, source: rootValue, errors: &errors)
        } catch let error as GraphQLError {
            // Matching Engine V1: an error propagating to the root yields absent data and only the
            // propagated error; accumulated field errors are discarded.
            return GraphQLResult(errors: [error])
        } catch {
            return GraphQLResult(errors: [GraphQLError(error)])
        }
        return GraphQLResult(data: .dictionary(data), errors: errors)
    }

    /// Executes the request through the fast path, or returns `nil` when the document is not
    /// eligible and Engine V1 must handle it. An invalid document the fast path reproduces exactly
    /// returns a `GraphQLResult` carrying the validation errors and no data, as Engine V1 does.
    static func run(
        schema: GraphQLSchema,
        request: String,
        rootValue: any Sendable,
        variableValues: [String: Map],
        operationName: String?
    ) -> GraphQLResult? {
        switch compilePlan(
            schema: schema,
            request: request,
            variableValues: variableValues,
            operationName: operationName
        ) {
        case let .plan(plan):
            return execute(plan: plan, rootValue: rootValue)
        case let .validationErrors(errors):
            return GraphQLResult(errors: errors)
        case .fallback:
            return nil
        }
    }

    // MARK: - Planning

    /// Outcome of fusing parse, name resolution, and structural validation for one request.
    enum PlanOutcome {
        /// The document is fully executable on the fast path.
        case plan(Plan)
        /// The document is invalid in a way the fast path reproduces exactly (currently unknown
        /// fields); these errors match Engine V1's message, suggestions, and source location.
        case validationErrors([GraphQLError])
        /// The document uses a construct the fast path cannot prove equivalent; Engine V1 handles it.
        case fallback
    }

    /// A field that does not exist on its parent type, captured during planning so the exact Engine
    /// V1 `FieldsOnCorrectType` error can be reconstructed after the traversal.
    private struct UndefinedField {
        let fieldName: String
        let parentType: GraphQLOutputType
        let parentTypeName: String
        let position: Int
    }

    private final class Planner {
        let document: FastDocument
        let compiled: EngineV2CompiledSchema
        /// Unknown fields found in leaf position, in document (pre-order) order, matching the order
        /// Engine V1's validation visitor reports them.
        var undefinedFields: [UndefinedField] = []

        init(document: FastDocument, compiled: EngineV2CompiledSchema) {
            self.document = document
            self.compiled = compiled
        }

        /// Returns the planned fields, or `nil` when the selection set uses an unsupported construct
        /// and the whole request must fall back to Engine V1. An unknown field in leaf position is
        /// *not* a fallback: it is recorded in `undefinedFields` and skipped so planning can confirm
        /// the remainder of the document is otherwise fully supported before emitting the error.
        func planSelectionSet(
            _ selectionSetIndex: UInt32,
            parentType: FastSchemaTypeID
        ) -> [PlanField]? {
            let set = document.selectionSets[Int(selectionSetIndex)]
            guard set.selectionCount > 0 else { return nil }

            var fields: [PlanField] = []
            fields.reserveCapacity(Int(set.selectionCount))
            var seenKeys = Set<String>()

            let parentTypeName = compiled.metadata.name(
                compiled.metadata.types[Int(parentType.rawValue)].name
            )

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
                else {
                    // Unknown field. Only a leaf-position unknown field can be reproduced exactly:
                    // one whose absent type would make any child selection unvalidatable, so a child
                    // selection here forces a fallback rather than risk missing nested errors.
                    guard selection.selectionSet == nil else { return nil }
                    let parentType = compiled.namedTypes[Int(parentType.rawValue)]
                    guard let parentOutputType = parentType as? GraphQLOutputType else { return nil }
                    undefinedFields.append(UndefinedField(
                        fieldName: fieldName,
                        parentType: parentOutputType,
                        parentTypeName: parentTypeName,
                        position: Int(selection.alias?.start ?? nameRange.start)
                    ))
                    continue
                }
                let schemaField = compiled.metadata.fields[Int(fieldID.rawValue)]

                guard validateArguments(selection.arguments, schemaField: schemaField) else {
                    return nil
                }

                guard let resolver = planResolver(fieldID: fieldID) else { return nil }

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
            let reference = compiled.metadata.typeReferences[Int(typeReference.rawValue)]
            switch reference.kind {
            case .nonNull:
                guard let wrapped = reference.wrappedType,
                      let inner = planCompletion(
                          typeReference: wrapped,
                          childSelectionSet: childSelectionSet
                      )
                else { return nil }
                return .nonNull(inner)
            case .list:
                guard let wrapped = reference.wrappedType,
                      let inner = planCompletion(
                          typeReference: wrapped,
                          childSelectionSet: childSelectionSet
                      )
                else { return nil }
                return .list(inner)
            case .named:
                let namedType = compiled.namedTypes[Int(reference.namedType.rawValue)]
                if let leaf = namedType as? GraphQLLeafType {
                    guard childSelectionSet == nil else { return nil }
                    let stringCoercible = leaf as AnyObject === GraphQLString
                        || leaf as AnyObject === GraphQLID
                    return .leaf(leaf, stringCoercible: stringCoercible)
                }
                if let object = namedType as? GraphQLObjectType {
                    // Runtime type disambiguation is out of slice scope.
                    guard object.isTypeOf == nil else { return nil }
                    guard let childSelectionSet else { return nil }
                    guard let children = planSelectionSet(
                        childSelectionSet,
                        parentType: reference.namedType
                    ) else { return nil }
                    return .object(object, children: children)
                }
                // Unions, interfaces, and input objects fall back.
                return nil
            }
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
        // The source container's storage kind is identified at most once per object, then reused
        // for every default-keyed field, instead of re-running the existential-cast cascade per
        // field. Resolution is deferred so objects whose fields are all source-only pay nothing.
        var accessor: SourceAccessor?
        for field in fields {
            let resolved: (any Sendable)?
            switch field.resolver {
            case let .sourceOnly(thunk):
                resolved = try thunk(source)
            case .defaultKeyed:
                let container: SourceAccessor
                if let accessor {
                    container = accessor
                } else {
                    container = SourceAccessor(source: source)
                    accessor = container
                }
                resolved = container.value(forKey: field.fieldName)
            }
            let completed = try completeCatchingError(
                completion: field.completion,
                value: resolved,
                parentTypeName: field.parentTypeName,
                fieldName: field.fieldName,
                errors: &errors
            )
            results[field.responseKey] = completed ?? .null
        }
        return results
    }

    /// A source object's default-resolution storage, identified once. Precedence mirrors Engine
    /// V1's `extractKey`: `KeySubscriptable`, then `[String: any Sendable]`, then an ordered map,
    /// then reflection.
    private enum SourceAccessor {
        case keySubscriptable(KeySubscriptable)
        case stringDictionary([String: any Sendable])
        case orderedDictionary(OrderedDictionary<String, any Sendable>)
        case reflected(any Sendable)
        case empty

        init(source: any Sendable) {
            guard let source = unwrap(source) else { self = .empty; return }
            if let subscriptable = source as? KeySubscriptable {
                self = .keySubscriptable(subscriptable)
            } else if let dictionary = source as? [String: any Sendable] {
                self = .stringDictionary(dictionary)
            } else if let dictionary = source as? OrderedDictionary<String, any Sendable> {
                self = .orderedDictionary(dictionary)
            } else {
                self = .reflected(source)
            }
        }

        func value(forKey key: String) -> (any Sendable)? {
            switch self {
            case let .keySubscriptable(subscriptable): return subscriptable[key]
            case let .stringDictionary(dictionary): return dictionary[key]
            case let .orderedDictionary(dictionary): return dictionary[key]
            case let .reflected(source): return Mirror(reflecting: source).getValue(named: key)
            case .empty: return nil
            }
        }
    }

    /// Applies Engine V1's located-error boundary: an error (or null) in a non-null position
    /// propagates to null the parent, while a nullable position captures the error and becomes null.
    /// Applied per field and per list element.
    private static func completeCatchingError(
        completion: PlanCompletion,
        value: (any Sendable)?,
        parentTypeName: String,
        fieldName: String,
        errors: inout [GraphQLError]
    ) throws -> Map? {
        if completion.isNonNull {
            return try completeValue(
                completion: completion,
                value: value,
                parentTypeName: parentTypeName,
                fieldName: fieldName,
                errors: &errors
            )
        }
        do {
            return try completeValue(
                completion: completion,
                value: value,
                parentTypeName: parentTypeName,
                fieldName: fieldName,
                errors: &errors
            )
        } catch let error as GraphQLError {
            errors.append(error)
            return nil
        }
    }

    private static func completeValue(
        completion: PlanCompletion,
        value: (any Sendable)?,
        parentTypeName: String,
        fieldName: String,
        errors: inout [GraphQLError]
    ) throws -> Map? {
        switch completion {
        case let .nonNull(inner):
            guard let completed = try completeValue(
                completion: inner,
                value: value,
                parentTypeName: parentTypeName,
                fieldName: fieldName,
                errors: &errors
            ) else {
                throw nonNullError(parentTypeName: parentTypeName, fieldName: fieldName)
            }
            return completed
        case let .leaf(leaf, stringCoercible):
            guard let value, let unwrapped = unwrap(value) else { return nil }
            if stringCoercible, let string = unwrapped as? String {
                return .string(string)
            }
            return try leaf.serialize(value: unwrapped)
        case let .object(_, children):
            guard let value, let unwrapped = unwrap(value) else { return nil }
            return .dictionary(try execute(fields: children, source: unwrapped, errors: &errors))
        case let .list(inner):
            guard let value, let unwrapped = unwrap(value) else { return nil }
            guard let items = unwrapped as? [(any Sendable)?] else {
                throw GraphQLError(
                    message: "Expected array, but did not find one for field \(parentTypeName).\(fieldName)."
                )
            }
            var completed = [Map]()
            completed.reserveCapacity(items.count)
            for item in items {
                let element = try completeCatchingError(
                    completion: inner,
                    value: item,
                    parentTypeName: parentTypeName,
                    fieldName: fieldName,
                    errors: &errors
                )
                completed.append(element ?? .null)
            }
            return .array(completed)
        }
    }

    private static func nonNullError(parentTypeName: String, fieldName: String) -> GraphQLError {
        GraphQLError(
            message: "Cannot return null for non-nullable field \(parentTypeName).\(fieldName)."
        )
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

/// An opaque, precompiled Engine V2 plan for benchmark reuse.
@_spi(EngineV2Benchmark)
public struct EngineV2BenchmarkPlan {
    let plan: EngineV2Execute.Plan
}

/// Parse + fuse the request into a numeric execution plan. Returns the planned top-level field
/// count, or `nil` when the fast path is not eligible.
@_spi(EngineV2Benchmark)
public func engineV2CompileSingleItemPlan(
    _ schema: GraphQLSchema,
    _ request: String
) -> EngineV2BenchmarkPlan? {
    if case let .plan(plan) = EngineV2Execute.compilePlan(
        schema: schema,
        request: request,
        variableValues: [:],
        operationName: nil
    ) {
        return EngineV2BenchmarkPlan(plan: plan)
    }
    return nil
}

@_spi(EngineV2Benchmark)
public func engineV2PlanFieldCount(_ plan: EngineV2BenchmarkPlan) -> Int {
    plan.plan.fields.count
}

/// Execute a precompiled plan. Isolates execution + materialization from parse/plan cost.
@_spi(EngineV2Benchmark)
public func engineV2ExecutePlan(
    _ plan: EngineV2BenchmarkPlan,
    rootValue: any Sendable = ()
) -> GraphQLResult {
    EngineV2Execute.execute(plan: plan.plan, rootValue: rootValue)
}
