import Dispatch
import Foundation
import OrderedCollections

/*
 * Terminology
 *
 * "Definitions" are the generic name for top-level statements in the document.
 * Examples of this include:
 * 1) Operations (such as a query)
 * 2) Fragments
 *
 * "Operations" are a generic name for requests in the document.
 * Examples of this include:
 * 1) query,
 * 2) mutation
 *
 * "Selections" are the definitions that can appear legally and at
 * single level of the query. These include:
 * 1) field references e.g "a"
 * 2) fragment "spreads" e.g. "...c"
 * 3) inline fragment "spreads" e.g. "...on Type { a }"
 */

/**
 * Data that must be available at all points during query execution.
 *
 * Namely, schema of the type system that is currently executing,
 * and the fragments defined in the query document
 */
public final class ExecutionContext: @unchecked Sendable {
    let queryStrategy: QueryFieldExecutionStrategy = SerialFieldExecutionStrategy()
    let mutationStrategy: MutationFieldExecutionStrategy = SerialFieldExecutionStrategy()
    let subscriptionStrategy: SubscriptionFieldExecutionStrategy =
        ConcurrentFieldExecutionStrategy()
    public let schema: GraphQLSchema
    public let fragments: [String: FragmentDefinition]
    public let rootValue: any Sendable
    public let context: any Sendable
    public let operation: OperationDefinition
    public let variableValues: [String: Map]

    private var _errors: [GraphQLError]
    private var collectedFieldsCache: [CollectedFieldsCacheKey: OrderedDictionary<String, [Field]>] = [:]
    private let collectedFieldsCacheLock = NSLock()
    private let errorsQueue = DispatchQueue(
        label: "graphql.schema.validationerrors",
        attributes: .concurrent
    )
    public var errors: [GraphQLError] {
        get {
            // Reads can occur concurrently.
            return errorsQueue.sync {
                _errors
            }
        }
        set {
            // Writes occur sequentially.
            return errorsQueue.sync(flags: .barrier) {
                self._errors = newValue
            }
        }
    }

    init(
        schema: GraphQLSchema,
        fragments: [String: FragmentDefinition],
        rootValue: any Sendable,
        context: any Sendable,
        operation: OperationDefinition,
        variableValues: [String: Map],
        errors: [GraphQLError]
    ) {
        self.schema = schema
        self.fragments = fragments
        self.rootValue = rootValue
        self.context = context
        self.operation = operation
        self.variableValues = variableValues
        _errors = errors
    }

    public func append(error: GraphQLError) {
        // `append` must explicitly use the DispatchQueue and the underlying storage because by
        // default `append` uses separate unblocked get, modify, and replace steps.
        errorsQueue.sync(flags: .barrier) {
            self._errors.append(error)
        }
    }

    func collectedFields(
        runtimeType: GraphQLObjectType,
        selectionSet: SelectionSet
    ) throws -> OrderedDictionary<String, [Field]> {
        collectedFieldsCacheLock.lock()
        defer { collectedFieldsCacheLock.unlock() }

        let key = CollectedFieldsCacheKey(
            runtimeType: ObjectIdentifier(runtimeType),
            selectionSet: ObjectIdentifier(selectionSet)
        )
        if let cached = collectedFieldsCache[key] {
            return cached
        }

        var fields: OrderedDictionary<String, [Field]> = [:]
        var visitedFragmentNames: [String: Bool] = [:]
        let collected = try collectFields(
            exeContext: self,
            runtimeType: runtimeType,
            selectionSet: selectionSet,
            fields: &fields,
            visitedFragmentNames: &visitedFragmentNames
        )
        collectedFieldsCache[key] = collected
        return collected
    }
}

private struct CollectedFieldsCacheKey: Hashable {
    let runtimeType: ObjectIdentifier
    let selectionSet: ObjectIdentifier
}

public protocol FieldExecutionStrategy: Sendable {
    func executeFields(
        exeContext: ExecutionContext,
        parentType: GraphQLObjectType,
        sourceValue: any Sendable,
        path: IndexPath,
        fields: OrderedDictionary<String, [Field]>
    ) async throws -> OrderedDictionary<String, Map>
}

public protocol MutationFieldExecutionStrategy: FieldExecutionStrategy {}
public protocol QueryFieldExecutionStrategy: FieldExecutionStrategy {}
public protocol SubscriptionFieldExecutionStrategy: FieldExecutionStrategy {}

/**
 * Serial field execution strategy that's suitable for the "Evaluating selection sets" section of the spec for "write" mode.
 */
public struct SerialFieldExecutionStrategy: QueryFieldExecutionStrategy,
    MutationFieldExecutionStrategy, SubscriptionFieldExecutionStrategy
{
    public init() {}

    public func executeFields(
        exeContext: ExecutionContext,
        parentType: GraphQLObjectType,
        sourceValue: any Sendable,
        path: IndexPath,
        fields: OrderedDictionary<String, [Field]>
    ) async throws -> OrderedDictionary<String, Map> {
        var results = OrderedDictionary<String, Map>()
        for field in fields {
            let fieldASTs = field.value
            let fieldPath = path.appending(field.key)
            results[field.key] = try await resolveField(
                exeContext: exeContext,
                parentType: parentType,
                source: sourceValue,
                fieldASTs: fieldASTs,
                path: fieldPath
            ) ?? Map.null
        }
        return results
    }
}

/**
 * Serial field execution strategy that's suitable for the "Evaluating selection sets" section of the spec for "read" mode.
 *
 * Each field is resolved as an individual task on a concurrent dispatch queue.
 */
public struct ConcurrentFieldExecutionStrategy: QueryFieldExecutionStrategy,
    SubscriptionFieldExecutionStrategy
{
    public func executeFields(
        exeContext: ExecutionContext,
        parentType: GraphQLObjectType,
        sourceValue: any Sendable,
        path: IndexPath,
        fields: OrderedDictionary<String, [Field]>
    ) async throws -> OrderedDictionary<String, Map> {
        return try await withThrowingTaskGroup(of: (String, Map).self) { group in
            // preserve field order by assigning to null and filtering later
            var results: OrderedDictionary<String, Map> = fields.mapValues { _ in .null }
            for field in fields {
                group.addTask {
                    let fieldASTs = field.value
                    let fieldPath = path.appending(field.key)
                    let result = try await resolveField(
                        exeContext: exeContext,
                        parentType: parentType,
                        source: sourceValue,
                        fieldASTs: fieldASTs,
                        path: fieldPath
                    ) ?? Map.null
                    return (field.key, result)
                }
            }
            for try await result in group {
                results[result.0] = result.1
            }
            return results
        }
    }
}

/**
 * Implements the "Evaluating requests" section of the GraphQL specification.
 *
 * If the arguments to this func do not result in a legal execution context,
 * a GraphQLError will be thrown immediately explaining the invalid input.
 */
public func execute(
    schema: GraphQLSchema,
    documentAST: Document,
    rootValue: any Sendable,
    context: any Sendable,
    variableValues: [String: Map] = [:],
    operationName: String? = nil
) async throws -> GraphQLResult {
    let buildContext: ExecutionContext

    do {
        // If a valid context cannot be created due to incorrect arguments,
        // this will throw an error.
        buildContext = try buildExecutionContext(
            schema: schema,
            documentAST: documentAST,
            rootValue: rootValue,
            context: context,
            rawVariableValues: variableValues,
            operationName: operationName
        )
    } catch let error as GraphQLError {
        return GraphQLResult(errors: [error])
    } catch {
        return GraphQLResult(errors: [GraphQLError(error)])
    }

    do {
//        var executeErrors: [GraphQLError] = []
        let data = try await executeOperation(
            exeContext: buildContext,
            operation: buildContext.operation,
            rootValue: rootValue
        )
        var result: GraphQLResult = .init(data: .dictionary(data))

        if !buildContext.errors.isEmpty {
            result.errors = buildContext.errors
        }

//            executeErrors = buildContext.errors
        return result
    } catch let error as GraphQLError {
        return GraphQLResult(errors: [error])
    } catch {
        return GraphQLResult(errors: [GraphQLError(error)])
    }
}

/**
 * Constructs a ExecutionContext object from the arguments passed to
 * execute, which we will pass throughout the other execution methods.
 *
 * Throws a GraphQLError if a valid execution context cannot be created.
 */
func buildExecutionContext(
    schema: GraphQLSchema,
    documentAST: Document,
    rootValue: any Sendable,
    context: any Sendable,
    rawVariableValues: [String: Map],
    operationName: String?
) throws -> ExecutionContext {
    let errors: [GraphQLError] = []
    var possibleOperation: OperationDefinition?
    var fragments: [String: FragmentDefinition] = [:]

    for definition in documentAST.definitions {
        switch definition {
        case let definition as OperationDefinition:
            guard !(operationName == nil && possibleOperation != nil) else {
                throw GraphQLError(
                    message: "Must provide operation name if query contains multiple operations."
                )
            }

            if operationName == nil || definition.name?.value == operationName {
                possibleOperation = definition
            }

        case let definition as FragmentDefinition:
            fragments[definition.name.value] = definition

        default:
            throw GraphQLError(
                message: "GraphQL cannot execute a request containing a \(definition.kind).",
                nodes: [definition]
            )
        }
    }

    guard let operation = possibleOperation else {
        if let operationName = operationName {
            throw GraphQLError(message: "Unknown operation named \"\(operationName)\".")
        } else {
            throw GraphQLError(message: "Must provide an operation.")
        }
    }

    let variableValues = try getVariableValues(
        schema: schema,
        definitionASTs: operation.variableDefinitions,
        inputs: rawVariableValues
    )

    return ExecutionContext(
        schema: schema,
        fragments: fragments,
        rootValue: rootValue,
        context: context,
        operation: operation,
        variableValues: variableValues,
        errors: errors
    )
}

/**
 * Implements the "Evaluating operations" section of the spec.
 */
func executeOperation(
    exeContext: ExecutionContext,
    operation: OperationDefinition,
    rootValue: any Sendable
) async throws -> OrderedDictionary<String, Map> {
    let type = try getOperationRootType(schema: exeContext.schema, operation: operation)
    var inputFields: OrderedDictionary<String, [Field]> = [:]
    var visitedFragmentNames: [String: Bool] = [:]

    let fields = try collectFields(
        exeContext: exeContext,
        runtimeType: type,
        selectionSet: operation.selectionSet,
        fields: &inputFields,
        visitedFragmentNames: &visitedFragmentNames
    )

    let fieldExecutionStrategy: FieldExecutionStrategy

    switch operation.operation {
    case .query:
        if let plan = try buildSynchronousPlan(
            exeContext: exeContext,
            parentType: type,
            fields: fields
        ) {
            return try executeFieldsSynchronously(
                exeContext: exeContext,
                parentType: type,
                sourceValue: rootValue,
                path: [],
                plan: plan
            )
        }
        fieldExecutionStrategy = exeContext.queryStrategy
    case .mutation:
        if let plan = try buildSynchronousPlan(
            exeContext: exeContext,
            parentType: type,
            fields: fields
        ) {
            return try executeFieldsSynchronously(
                exeContext: exeContext,
                parentType: type,
                sourceValue: rootValue,
                path: [],
                plan: plan
            )
        }
        fieldExecutionStrategy = exeContext.mutationStrategy
    case .subscription:
        fieldExecutionStrategy = exeContext.subscriptionStrategy
    }

    return try await fieldExecutionStrategy.executeFields(
        exeContext: exeContext,
        parentType: type,
        sourceValue: rootValue,
        path: [],
        fields: fields
    )
}

/// Returns true only when the complete selection can be resolved without entering an async
/// resolver. This read-only preflight lets ordinary key-path and synchronous Graphiti schemas use
/// a completion engine with no Swift concurrency state machines, while preserving the async path
/// for mixed and genuinely asynchronous schemas.
private struct SynchronousFieldPlan {
    let responseName: String
    let fieldASTs: [Field]
    let fieldDefinition: GraphQLFieldDefinition
    let children: [SynchronousFieldPlan]?
}

private func buildSynchronousPlan(
    exeContext: ExecutionContext,
    parentType: GraphQLObjectType,
    fields: OrderedDictionary<String, [Field]>
) throws -> [SynchronousFieldPlan]? {
    var plan: [SynchronousFieldPlan] = []
    plan.reserveCapacity(fields.count)
    for (responseName, fieldASTs) in fields {
        let fieldName = fieldASTs[0].name.value
        let fieldDef = try getFieldDef(
            schema: exeContext.schema,
            parentType: parentType,
            fieldName: fieldName
        )
        if fieldDef.synchronousResolve == nil, fieldDef.resolve != nil {
            return nil
        }

        var children: [SynchronousFieldPlan]?
        guard let objectType = objectType(from: fieldDef.type) else {
            if containsAbstractType(fieldDef.type) {
                return nil
            }
            plan.append(.init(
                responseName: responseName,
                fieldASTs: fieldASTs,
                fieldDefinition: fieldDef,
                children: nil
            ))
            continue
        }
        let subfields = try collectSubfields(
            exeContext: exeContext,
            runtimeType: objectType,
            fieldASTs: fieldASTs
        )
        guard let childPlan = try buildSynchronousPlan(
            exeContext: exeContext,
            parentType: objectType,
            fields: subfields
        ) else { return nil }
        children = childPlan
        plan.append(.init(
            responseName: responseName,
            fieldASTs: fieldASTs,
            fieldDefinition: fieldDef,
            children: children
        ))
    }
    return plan
}

private func objectType(from type: GraphQLType) -> GraphQLObjectType? {
    if let nonNull = type as? GraphQLNonNull {
        return objectType(from: nonNull.ofType)
    }
    if let list = type as? GraphQLList {
        return objectType(from: list.ofType)
    }
    return type as? GraphQLObjectType
}

private func containsAbstractType(_ type: GraphQLType) -> Bool {
    if let nonNull = type as? GraphQLNonNull {
        return containsAbstractType(nonNull.ofType)
    }
    if let list = type as? GraphQLList {
        return containsAbstractType(list.ofType)
    }
    return type is GraphQLAbstractType
}

private func collectSubfields(
    exeContext: ExecutionContext,
    runtimeType: GraphQLObjectType,
    fieldASTs: [Field]
) throws -> OrderedDictionary<String, [Field]> {
    if fieldASTs.count == 1, let selectionSet = fieldASTs[0].selectionSet {
        return try exeContext.collectedFields(runtimeType: runtimeType, selectionSet: selectionSet)
    }

    var collected: OrderedDictionary<String, [Field]> = [:]
    var visitedFragmentNames: [String: Bool] = [:]
    for fieldAST in fieldASTs {
        if let selectionSet = fieldAST.selectionSet {
            collected = try collectFields(
                exeContext: exeContext,
                runtimeType: runtimeType,
                selectionSet: selectionSet,
                fields: &collected,
                visitedFragmentNames: &visitedFragmentNames
            )
        }
    }
    return collected
}

private func executeFieldsSynchronously(
    exeContext: ExecutionContext,
    parentType: GraphQLObjectType,
    sourceValue: any Sendable,
    path: IndexPath,
    plan: [SynchronousFieldPlan]
) throws -> OrderedDictionary<String, Map> {
    var results = OrderedDictionary<String, Map>(minimumCapacity: plan.count)
    for field in plan {
        results[field.responseName] = try resolveFieldSynchronously(
            exeContext: exeContext,
            parentType: parentType,
            source: sourceValue,
            field: field,
            parentPath: path
        ) ?? .null
    }
    return results
}

private func resolveFieldSynchronously(
    exeContext: ExecutionContext,
    parentType: GraphQLObjectType,
    source: any Sendable,
    field: SynchronousFieldPlan,
    parentPath: IndexPath
) throws -> Map? {
    let fieldASTs = field.fieldASTs
    let fieldAST = fieldASTs[0]
    let fieldName = fieldAST.name.value
    let fieldDef = field.fieldDefinition
    if fieldDef.fastResolveIsComplete, let fastResolve = fieldDef.fastResolve {
        do {
            guard let resolved = try fastResolve(source), let completed = resolved as? Map else {
                throw GraphQLError(
                    message: "Cannot return null for non-nullable field \(parentType.name).\(fieldName)."
                )
            }
            return completed
        } catch {
            throw locatedError(
                originalError: error,
                nodes: fieldASTs,
                path: parentPath.appending(field.responseName)
            )
        }
    }
    if parentType.name.hasPrefix("__") {
        if fieldName == "name", let name = introspectionName(source) {
            return .string(name)
        }
        if fieldName == "kind", let kind = introspectionKind(source) {
            return .string(kind.rawValue)
        }
        if fieldName == "locations", let directive = source as? GraphQLDirective {
            return .array(directive.locations.map { .string($0.rawValue) })
        }
    }
    let path = parentPath.appending(field.responseName)
    let args: Map
    if fieldDef.args.isEmpty, fieldAST.arguments.isEmpty {
        args = [:]
    } else {
        args = try getArgumentValues(
            argDefs: fieldDef.args,
            argASTs: fieldAST.arguments,
            variables: exeContext.variableValues
        )
    }
    let info: GraphQLResolveInfo? = fieldDef.fastResolve == nil
        ? makeResolveInfo(
            exeContext: exeContext,
            fieldName: fieldName,
            fieldASTs: fieldASTs,
            returnType: fieldDef.type,
            parentType: parentType,
            path: path
        )
        : nil
    let result: Result<(any Sendable)?, Error>
    if let fastResolve = fieldDef.fastResolve {
        do {
            result = .success(try fastResolve(source))
        } catch {
            result = .failure(error)
        }
    } else {
        result = resolveOrError(
            resolve: fieldDef.synchronousResolve ?? defaultResolve,
            source: source,
            args: args,
            context: exeContext.context,
            info: info!
        )
    }
    return try completeValueCatchingErrorSynchronously(
        exeContext: exeContext,
        returnType: fieldDef.type,
        fieldASTs: fieldASTs,
        info: info,
        parentType: parentType,
        fieldName: fieldName,
        path: path,
        result: result,
        childPlan: field.children
    )
}

private func introspectionName(_ source: any Sendable) -> String? {
    if let value = source as? GraphQLNamedType { return value.name }
    if let value = source as? GraphQLFieldDefinition { return value.name }
    if let value = source as? GraphQLArgumentDefinition { return value.name }
    if let value = source as? GraphQLDirective { return value.name }
    if let value = source as? GraphQLEnumValueDefinition { return value.name }
    if let value = source as? InputObjectFieldDefinition { return value.name }
    return nil
}

private func introspectionKind(_ source: any Sendable) -> TypeKind? {
    switch source {
    case is GraphQLScalarType: return .scalar
    case is GraphQLObjectType: return .object
    case is GraphQLInterfaceType: return .interface
    case is GraphQLUnionType: return .union
    case is GraphQLEnumType: return .enum
    case is GraphQLInputObjectType: return .inputObject
    case is GraphQLList: return .list
    case is GraphQLNonNull: return .nonNull
    default: return nil
    }
}

private func completeValueCatchingErrorSynchronously(
    exeContext: ExecutionContext,
    returnType: GraphQLType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo?,
    parentType: GraphQLObjectType,
    fieldName: String,
    path: IndexPath,
    result: Result<(any Sendable)?, Error>,
    childPlan: [SynchronousFieldPlan]?
) throws -> Map? {
    if returnType is GraphQLNonNull {
        return try completeValueWithLocatedErrorSynchronously(
            exeContext: exeContext,
            returnType: returnType,
            fieldASTs: fieldASTs,
            info: info,
            parentType: parentType,
            fieldName: fieldName,
            path: path,
            result: result,
            childPlan: childPlan
        )
    }
    do {
        return try completeValueWithLocatedErrorSynchronously(
            exeContext: exeContext,
            returnType: returnType,
            fieldASTs: fieldASTs,
            info: info,
            parentType: parentType,
            fieldName: fieldName,
            path: path,
            result: result,
            childPlan: childPlan
        )
    } catch let error as GraphQLError {
        exeContext.append(error: error)
        return nil
    }
}

private func completeValueWithLocatedErrorSynchronously(
    exeContext: ExecutionContext,
    returnType: GraphQLType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo?,
    parentType: GraphQLObjectType,
    fieldName: String,
    path: IndexPath,
    result: Result<(any Sendable)?, Error>,
    childPlan: [SynchronousFieldPlan]?
) throws -> Map? {
    do {
        return try completeValueSynchronously(
            exeContext: exeContext,
            returnType: returnType,
            fieldASTs: fieldASTs,
            info: info,
            parentType: parentType,
            fieldName: fieldName,
            path: path,
            result: result,
            childPlan: childPlan
        )
    } catch {
        throw locatedError(originalError: error, nodes: fieldASTs, path: path)
    }
}

private func completeValueSynchronously(
    exeContext: ExecutionContext,
    returnType: GraphQLType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo?,
    parentType: GraphQLObjectType,
    fieldName: String,
    path: IndexPath,
    result: Result<(any Sendable)?, Error>,
    childPlan: [SynchronousFieldPlan]?
) throws -> Map? {
    let resolved: (any Sendable)?
    switch result {
    case let .failure(error):
        throw error
    case let .success(value):
        resolved = value
    }

    if let nonNull = returnType as? GraphQLNonNull {
        let value = try completeValueSynchronously(
            exeContext: exeContext,
            returnType: nonNull.ofType,
            fieldASTs: fieldASTs,
            info: info,
            parentType: parentType,
            fieldName: fieldName,
            path: path,
            result: .success(resolved),
            childPlan: childPlan
        )
        guard let value else {
            throw GraphQLError(
                message: "Cannot return null for non-nullable field \(parentType.name).\(fieldName)."
            )
        }
        return value
    }

    guard let resolved, let value = unwrap(resolved) else {
        return nil
    }
    if let list = returnType as? GraphQLList {
        guard let items = value as? [(any Sendable)?] else {
            throw GraphQLError(
                message: "Expected array, but did not find one for field \(parentType.name).\(fieldName)."
            )
        }
        var completed = [Map]()
        completed.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            completed.append(try completeValueCatchingErrorSynchronously(
                exeContext: exeContext,
                returnType: list.ofType,
                fieldASTs: fieldASTs,
                info: info,
                parentType: parentType,
                fieldName: fieldName,
                path: path.appending(index),
                result: .success(item),
                childPlan: childPlan
            ) ?? .null)
        }
        return .array(completed)
    }
    if let leaf = returnType as? GraphQLLeafType {
        return try completeLeafValue(returnType: leaf, result: value)
    }
    guard let object = returnType as? GraphQLObjectType else {
        throw GraphQLError(message: "Cannot synchronously complete value of type \(returnType).")
    }
    if let isTypeOf = object.isTypeOf {
        let resolveInfo = info ?? makeResolveInfo(
            exeContext: exeContext,
            fieldName: fieldName,
            fieldASTs: fieldASTs,
            returnType: returnType as! GraphQLOutputType,
            parentType: parentType,
            path: path
        )
        if try !isTypeOf(value, resolveInfo) {
        throw GraphQLError(
            message: "Expected value of type \"\(object.name)\" but got: \(value).",
            nodes: fieldASTs
        )
        }
    }
    guard let childPlan else {
        throw GraphQLError(message: "Missing synchronous plan for object type \(object.name).")
    }
    return .dictionary(try executeFieldsSynchronously(
        exeContext: exeContext,
        parentType: object,
        sourceValue: value,
        path: path,
        plan: childPlan
    ))
}

private func makeResolveInfo(
    exeContext: ExecutionContext,
    fieldName: String,
    fieldASTs: [Field],
    returnType: GraphQLOutputType,
    parentType: GraphQLObjectType,
    path: IndexPath
) -> GraphQLResolveInfo {
    GraphQLResolveInfo(
        fieldName: fieldName,
        fieldASTs: fieldASTs,
        returnType: returnType,
        parentType: parentType,
        path: path,
        schema: exeContext.schema,
        fragments: exeContext.fragments,
        rootValue: exeContext.rootValue,
        operation: exeContext.operation,
        variableValues: exeContext.variableValues
    )
}

/**
 * Extracts the root type of the operation from the schema.
 */
func getOperationRootType(
    schema: GraphQLSchema,
    operation: OperationDefinition
) throws -> GraphQLObjectType {
    switch operation.operation {
    case .query:
        guard let queryType = schema.queryType else {
            throw GraphQLError(
                message: "Schema is not configured for queries",
                nodes: [operation]
            )
        }

        return queryType
    case .mutation:
        guard let mutationType = schema.mutationType else {
            throw GraphQLError(
                message: "Schema is not configured for mutations",
                nodes: [operation]
            )
        }

        return mutationType
    case .subscription:
        guard let subscriptionType = schema.subscriptionType else {
            throw GraphQLError(
                message: "Schema is not configured for subscriptions",
                nodes: [operation]
            )
        }

        return subscriptionType
    }
}

/**
 * Given a selectionSet, adds all of the fields in that selection to
 * the passed in map of fields, and returns it at the end.
 *
 * CollectFields requires the "runtime type" of an object. For a field which
 * returns and Interface or Union type, the "runtime type" will be the actual
 * Object type returned by that field.
 */
@discardableResult
func collectFields(
    exeContext: ExecutionContext,
    runtimeType: GraphQLObjectType,
    selectionSet: SelectionSet,
    fields: inout OrderedDictionary<String, [Field]>,
    visitedFragmentNames: inout [String: Bool]
) throws -> OrderedDictionary<String, [Field]> {
    var visitedFragmentNames = visitedFragmentNames

    for selection in selectionSet.selections {
        switch selection {
        case let field as Field:
            let shouldInclude = try shouldIncludeNode(
                exeContext: exeContext,
                directives: field.directives
            )

            guard shouldInclude else {
                continue
            }

            let name = getFieldEntryKey(node: field)

            if fields[name] == nil {
                fields[name] = []
            }

            fields[name]?.append(field)
        case let inlineFragment as InlineFragment:
            let shouldInclude = try shouldIncludeNode(
                exeContext: exeContext,
                directives: inlineFragment.directives
            )

            let fragmentConditionMatches = try doesFragmentConditionMatch(
                exeContext: exeContext,
                fragment: inlineFragment,
                type: runtimeType
            )

            guard shouldInclude, fragmentConditionMatches else {
                continue
            }

            try collectFields(
                exeContext: exeContext,
                runtimeType: runtimeType,
                selectionSet: inlineFragment.selectionSet,
                fields: &fields,
                visitedFragmentNames: &visitedFragmentNames
            )
        case let fragmentSpread as FragmentSpread:
            let fragmentName = fragmentSpread.name.value

            let shouldInclude = try shouldIncludeNode(
                exeContext: exeContext,
                directives: fragmentSpread.directives
            )

            guard visitedFragmentNames[fragmentName] == nil, shouldInclude else {
                continue
            }

            visitedFragmentNames[fragmentName] = true

            guard let fragment = exeContext.fragments[fragmentName] else {
                continue
            }

            let fragmentConditionMatches = try doesFragmentConditionMatch(
                exeContext: exeContext,
                fragment: fragment,
                type: runtimeType
            )

            guard fragmentConditionMatches else {
                continue
            }

            try collectFields(
                exeContext: exeContext,
                runtimeType: runtimeType,
                selectionSet: fragment.selectionSet,
                fields: &fields,
                visitedFragmentNames: &visitedFragmentNames
            )
        default:
            break
        }
    }

    return fields
}

/**
 * Determines if a field should be included based on the @include and @skip
 * directives, where @skip has higher precidence than @include.
 */
func shouldIncludeNode(exeContext: ExecutionContext, directives: [Directive] = []) throws -> Bool {
    if let skipAST = directives.find({ $0.name.value == GraphQLSkipDirective.name }) {
        let skip = try getArgumentValues(
            argDefs: GraphQLSkipDirective.args,
            argASTs: skipAST.arguments,
            variables: exeContext.variableValues
        )

        if skip["if"] == .bool(true) {
            return false
        }
    }

    if let includeAST = directives.find({ $0.name.value == GraphQLIncludeDirective.name }) {
        let include = try getArgumentValues(
            argDefs: GraphQLIncludeDirective.args,
            argASTs: includeAST.arguments,
            variables: exeContext.variableValues
        )

        if include["if"] == .bool(false) {
            return false
        }
    }

    return true
}

/**
 * Determines if a fragment is applicable to the given type.
 */
func doesFragmentConditionMatch(
    exeContext: ExecutionContext,
    fragment: HasTypeCondition,
    type: GraphQLObjectType
) throws -> Bool {
    guard let typeConditionAST = fragment.getTypeCondition() else {
        return true
    }

    guard
        let conditionalType = typeFromAST(
            schema: exeContext.schema,
            inputTypeAST: typeConditionAST
        )
    else {
        return true
    }

    if
        let conditionalType = conditionalType as? GraphQLObjectType,
        conditionalType.name == type.name
    {
        return true
    }

    if let abstractType = conditionalType as? GraphQLAbstractType {
        return exeContext.schema.isSubType(
            abstractType: abstractType,
            maybeSubType: type
        )
    }

    return false
}

/**
 * Implements the logic to compute the key of a given field's entry
 */
func getFieldEntryKey(node: Field) -> String {
    return node.alias?.value ?? node.name.value
}

/**
 * Resolves the field on the given source object. In particular, this
 * figures out the value that the field returns by calling its resolve func,
 * then calls completeValue to complete promises, serialize scalars, or execute
 * the sub-selection-set for objects.
 */
public func resolveField(
    exeContext: ExecutionContext,
    parentType: GraphQLObjectType,
    source: any Sendable,
    fieldASTs: [Field],
    path: IndexPath
) async throws -> Map? {
    let fieldAST = fieldASTs[0]
    let fieldName = fieldAST.name.value

    let fieldDef = try getFieldDef(
        schema: exeContext.schema,
        parentType: parentType,
        fieldName: fieldName
    )

    let returnType = fieldDef.type
    let fastResolve = fieldDef.fastResolve
    let synchronousResolve = fieldDef.synchronousResolve
    let resolve = fieldDef.resolve

    // Build a Map object of arguments from the field.arguments AST, using the
    // variables scope to fulfill any variable references.
    // TODO: find a way to memoize, in case this field is within a List type.
    let args: Map
    if fieldDef.args.isEmpty, fieldAST.arguments.isEmpty {
        args = [:]
    } else {
        args = try getArgumentValues(
            argDefs: fieldDef.args,
            argASTs: fieldAST.arguments,
            variables: exeContext.variableValues
        )
    }

    // The resolve func's optional third argument is a context value that
    // is provided to every resolve func within an execution. It is commonly
    // used to represent an authenticated user, or request-specific caches.
    let context = exeContext.context

    // The resolve func's optional fourth argument is a collection of
    // information about the current execution state.
    let info = GraphQLResolveInfo(
        fieldName: fieldName,
        fieldASTs: fieldASTs,
        returnType: returnType,
        parentType: parentType,
        path: path,
        schema: exeContext.schema,
        fragments: exeContext.fragments,
        rootValue: exeContext.rootValue,
        operation: exeContext.operation,
        variableValues: exeContext.variableValues
    )

    // Get the resolve func, regardless of if its result is normal
    // or abrupt (error).
    let result: Result<(any Sendable)?, Error>
    if let fastResolve {
        do {
            result = .success(try fastResolve(source))
        } catch {
            result = .failure(error)
        }
    } else if let synchronousResolve {
        result = resolveOrError(
            resolve: synchronousResolve,
            source: source,
            args: args,
            context: context,
            info: info
        )
    } else if let resolve {
        result = await resolveOrError(
            resolve: resolve,
            source: source,
            args: args,
            context: context,
            info: info
        )
    } else {
        result = resolveOrError(
            resolve: defaultResolve,
            source: source,
            args: args,
            context: context,
            info: info
        )
    }

    return try await completeValueCatchingError(
        exeContext: exeContext,
        returnType: returnType,
        fieldASTs: fieldASTs,
        info: info,
        path: path,
        result: result
    )
}

/// Isolates the "ReturnOrAbrupt" behavior to not de-opt the `resolveField`
/// function. Returns the result of `resolve` or the abrupt-return Error object.
func resolveOrError(
    resolve: GraphQLFieldResolve,
    source: any Sendable,
    args: Map,
    context: any Sendable,
    info: GraphQLResolveInfo
) async -> Result<(any Sendable)?, Error> {
    do {
        let result = try await resolve(source, args, context, info)
        return .success(result)
    } catch {
        return .failure(error)
    }
}

func resolveOrError(
    resolve: GraphQLFieldResolveInput,
    source: any Sendable,
    args: Map,
    context: any Sendable,
    info: GraphQLResolveInfo
) -> Result<(any Sendable)?, Error> {
    do {
        return .success(try resolve(source, args, context, info))
    } catch {
        return .failure(error)
    }
}

/// This is a small wrapper around completeValue which detects and logs errors
/// in the execution context.
func completeValueCatchingError(
    exeContext: ExecutionContext,
    returnType: GraphQLType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo,
    path: IndexPath,
    result: Result<(any Sendable)?, Error>
) async throws -> Map? {
    // If the field type is non-nullable, then it is resolved without any
    // protection from errors, however it still properly locates the error.
    if let returnType = returnType as? GraphQLNonNull {
        return try await completeValueWithLocatedError(
            exeContext: exeContext,
            returnType: returnType,
            fieldASTs: fieldASTs,
            info: info,
            path: path,
            result: result
        )
    }

    // Otherwise, error protection is applied, logging the error and resolving
    // a null value for this field if one is encountered.
    do {
        return try await completeValueWithLocatedError(
            exeContext: exeContext,
            returnType: returnType,
            fieldASTs: fieldASTs,
            info: info,
            path: path,
            result: result
        )
    } catch let error as GraphQLError {
        // If `completeValueWithLocatedError` returned abruptly (threw an error),
        // log the error and return .null.
        exeContext.append(error: error)
        return nil
    } catch {
        throw error
    }
}

/// This is a small wrapper around completeValue which annotates errors with
/// location information.
func completeValueWithLocatedError(
    exeContext: ExecutionContext,
    returnType: GraphQLType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo,
    path: IndexPath,
    result: Result<(any Sendable)?, Error>
) async throws -> Map? {
    do {
        return try await completeValue(
            exeContext: exeContext,
            returnType: returnType,
            fieldASTs: fieldASTs,
            info: info,
            path: path,
            result: result
        )
    } catch {
        throw locatedError(
            originalError: error,
            nodes: fieldASTs,
            path: path
        )
    }
}

/**
 * Implements the instructions for completeValue as defined in the
 * "Field entries" section of the spec.
 *
 * If the field type is Non-Null, then this recursively completes the value
 * for the inner type. It throws a field error if that completion returns null,
 * as per the "Nullability" section of the spec.
 *
 * If the field type is a List, then this recursively completes the value
 * for the inner type on each item in the list.
 *
 * If the field type is a Scalar or Enum, ensures the completed value is a legal
 * value of the type by calling the `serialize` method of GraphQL type
 * definition.
 *
 * If the field is an abstract type, determine the runtime type of the value
 * and then complete based on that type
 *
 * Otherwise, the field type expects a sub-selection set, and will complete the
 * value by evaluating all sub-selections.
 */
func completeValue(
    exeContext: ExecutionContext,
    returnType: GraphQLType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo,
    path: IndexPath,
    result: Result<(any Sendable)?, Error>
) async throws -> Map? {
    switch result {
    case let .failure(error):
        throw error
    case let .success(result):
        // If field type is NonNull, complete for inner type, and throw field error
        // if result is nullish.
        if let returnType = returnType as? GraphQLNonNull {
            let value = try await completeValue(
                exeContext: exeContext,
                returnType: returnType.ofType,
                fieldASTs: fieldASTs,
                info: info,
                path: path,
                result: .success(result)
            )
            guard let value = value else {
                throw GraphQLError(
                    message: "Cannot return null for non-nullable field \(info.parentType.name).\(info.fieldName)."
                )
            }

            return value
        }

        // If result value is null-ish (nil or .null) then return .null.
        guard let result = result, let r = unwrap(result) else {
            return nil
        }

        // If field type is List, complete each item in the list with the inner type
        if let returnType = returnType as? GraphQLList {
            return try await completeListValue(
                exeContext: exeContext,
                returnType: returnType,
                fieldASTs: fieldASTs,
                info: info,
                path: path,
                result: r
            )
        }

        // If field type is a leaf type, Scalar or Enum, serialize to a valid value,
        // returning .null if serialization is not possible.
        if let returnType = returnType as? GraphQLLeafType {
            return try completeLeafValue(returnType: returnType, result: r)
        }

        // If field type is an abstract type, Interface or Union, determine the
        // runtime Object type and complete for that type.
        if let returnType = returnType as? GraphQLAbstractType {
            return try await completeAbstractValue(
                exeContext: exeContext,
                returnType: returnType,
                fieldASTs: fieldASTs,
                info: info,
                path: path,
                result: r
            )
        }

        // If field type is Object, execute and complete all sub-selections.
        if let returnType = returnType as? GraphQLObjectType {
            return try await completeObjectValue(
                exeContext: exeContext,
                returnType: returnType,
                fieldASTs: fieldASTs,
                info: info,
                path: path,
                result: r
            )
        }

        // Not reachable. All possible output types have been considered.
        throw GraphQLError(
            message: "Cannot complete value of unexpected type \"\(returnType)\"."
        )
    }
}

/**
 * Complete a list value by completing each item in the list with the
 * inner type
 */
func completeListValue(
    exeContext: ExecutionContext,
    returnType: GraphQLList,
    fieldASTs: [Field],
    info: GraphQLResolveInfo,
    path: IndexPath,
    result: any Sendable
) async throws -> Map {
    guard let result = result as? [(any Sendable)?] else {
        throw GraphQLError(
            message:
            "Expected array, but did not find one for field " +
                "\(info.parentType.name).\(info.fieldName)."
        )
    }

    let itemType = returnType.ofType

    var results = [Map]()
    results.reserveCapacity(result.count)
    for (index, item) in result.enumerated() {
        let fieldPath = path.appending(index)
        let completed = try await completeValueCatchingError(
            exeContext: exeContext,
            returnType: itemType,
            fieldASTs: fieldASTs,
            info: info,
            path: fieldPath,
            result: .success(item)
        )
        results.append(completed ?? .null)
    }
    return .array(results)
}

/**
 * Complete a Scalar or Enum by serializing to a valid value, returning
 * .null if serialization is not possible.
 */
func completeLeafValue(returnType: GraphQLLeafType, result: (any Sendable)?) throws -> Map {
    guard let result = result else {
        return .null
    }
    return try returnType.serialize(value: result)

    // Do not check for serialization to null here. Some scalars may model literals as `Map.null`.
}

/**
 * Complete a value of an abstract type by determining the runtime object type
 * of that value, then complete the value for that type.
 */
func completeAbstractValue(
    exeContext: ExecutionContext,
    returnType: GraphQLAbstractType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo,
    path: IndexPath,
    result: any Sendable
) async throws -> Map? {
    var resolveRes = try returnType.resolveType?(result, info)
        .typeResolveResult

    resolveRes = try resolveRes ?? defaultResolveType(
        value: result,
        info: info,
        abstractType: returnType
    )

    guard let resolveResult = resolveRes else {
        throw GraphQLError(
            message: "Could not find a resolve function.",
            nodes: fieldASTs
        )
    }

    // If resolveType returns a string, we assume it's a GraphQLObjectType name.
    var runtimeType: GraphQLType?

    switch resolveResult {
    case let .name(name):
        runtimeType = exeContext.schema.getType(name: name)
    case let .type(type):
        runtimeType = type
    }

    guard let objectType = runtimeType as? GraphQLObjectType else {
        throw GraphQLError(
            message:
            "Abstract type \(returnType.name) must resolve to an Object type at " +
                "runtime for field \(info.parentType.name).\(info.fieldName) with " +
                "value \"\(resolveResult)\", received \"\(String(describing: runtimeType))\".",
            nodes: fieldASTs
        )
    }

    if !exeContext.schema.isSubType(abstractType: returnType, maybeSubType: objectType) {
        throw GraphQLError(
            message:
            "Runtime Object type \"\(objectType.name)\" is not a possible type " +
                "for \"\(returnType.name)\".",
            nodes: fieldASTs
        )
    }

    return try await completeObjectValue(
        exeContext: exeContext,
        returnType: objectType,
        fieldASTs: fieldASTs,
        info: info,
        path: path,
        result: result
    )
}

/**
 * Complete an Object value by executing all sub-selections.
 */
func completeObjectValue(
    exeContext: ExecutionContext,
    returnType: GraphQLObjectType,
    fieldASTs: [Field],
    info: GraphQLResolveInfo,
    path: IndexPath,
    result: any Sendable
) async throws -> Map? {
    // If there is an isTypeOf predicate func, call it with the
    // current result. If isTypeOf returns false, then raise an error rather
    // than continuing execution.
    if
        let isTypeOf = returnType.isTypeOf,
        try !isTypeOf(result, info)
    {
        throw GraphQLError(
            message:
            "Expected value of type \"\(returnType.name)\" but got: \(result).",
            nodes: fieldASTs
        )
    }

    // Lists complete an identical selection set for every item. Cache that per-request plan
    // instead of walking and merging the AST again for each object.
    let subFieldASTs: OrderedDictionary<String, [Field]>
    if fieldASTs.count == 1, let selectionSet = fieldASTs[0].selectionSet {
        subFieldASTs = try exeContext.collectedFields(
            runtimeType: returnType,
            selectionSet: selectionSet
        )
    } else {
        var collected: OrderedDictionary<String, [Field]> = [:]
        var visitedFragmentNames: [String: Bool] = [:]
        for fieldAST in fieldASTs {
            if let selectionSet = fieldAST.selectionSet {
                collected = try collectFields(
                    exeContext: exeContext,
                    runtimeType: returnType,
                    selectionSet: selectionSet,
                    fields: &collected,
                    visitedFragmentNames: &visitedFragmentNames
                )
            }
        }
        subFieldASTs = collected
    }

    let completed = try await exeContext.queryStrategy.executeFields(
        exeContext: exeContext,
        parentType: returnType,
        sourceValue: result,
        path: path,
        fields: subFieldASTs
    )
    return .dictionary(completed)
}

/**
 * If a resolveType func is not given, then a default resolve behavior is
 * used which tests each possible type for the abstract type by calling
 * isTypeOf for the object being coerced, returning the first type that matches.
 */
func defaultResolveType(
    value: any Sendable,
    info: GraphQLResolveInfo,
    abstractType: GraphQLAbstractType
) throws -> TypeResolveResult? {
    let possibleTypes = info.schema.getPossibleTypes(abstractType: abstractType)

    guard
        let type = try possibleTypes
            .find({ try $0.isTypeOf?(value, info) ?? false })
    else {
        return nil
    }

    return .type(type)
}

/**
 * If a resolve func is not given, then a default resolve behavior is used
 * which takes the property of the source object of the same name as the field
 * and returns it as the result.
 */
func defaultResolve(
    source: any Sendable,
    args _: Map,
    context _: any Sendable,
    info: GraphQLResolveInfo
) throws -> (any Sendable)? {
    guard let source = unwrap(source) else {
        return nil
    }

    // Introspection traverses schema metadata rather than application models. Resolve its hottest
    // structural properties directly instead of constructing a Mirror for every selected field.
    switch info.fieldName {
    case "name":
        if let value = source as? GraphQLNamedType { return value.name }
        if let value = source as? GraphQLFieldDefinition { return value.name }
        if let value = source as? GraphQLArgumentDefinition { return value.name }
        if let value = source as? GraphQLDirective { return value.name }
        if let value = source as? GraphQLEnumValueDefinition { return value.name }
        if let value = source as? InputObjectFieldDefinition { return value.name }
    case "type":
        if let value = source as? GraphQLFieldDefinition { return value.type }
        if let value = source as? GraphQLArgumentDefinition { return value.type }
        if let value = source as? InputObjectFieldDefinition { return value.type }
    case "ofType":
        if let value = source as? GraphQLList { return value.ofType }
        if let value = source as? GraphQLNonNull { return value.ofType }
        return nil
    case "locations":
        if let value = source as? GraphQLDirective { return value.locations }
    default:
        break
    }

    if let subscriptable = source as? KeySubscriptable {
        return subscriptable[info.fieldName]
    }
    if let subscriptable = source as? [String: any Sendable] {
        return subscriptable[info.fieldName]
    }
    if let subscriptable = source as? OrderedDictionary<String, any Sendable> {
        return subscriptable[info.fieldName]
    }

    let mirror = Mirror(reflecting: source)
    return mirror.getValue(named: info.fieldName)
}

/**
 * This method looks up the field on the given type defintion.
 * It has special casing for the two introspection fields, __schema
 * and __typename. __typename is special because it can always be
 * queried as a field, even in situations where no other fields
 * are allowed, like on a Union. __schema could get automatically
 * added to the query type, but that would require mutating type
 * definitions, which would cause issues.
 */
func getFieldDef(
    schema: GraphQLSchema,
    parentType: GraphQLObjectType,
    fieldName: String
) throws -> GraphQLFieldDefinition {
    if fieldName == SchemaMetaFieldDef.name, schema.queryType?.name == parentType.name {
        return SchemaMetaFieldDef
    } else if fieldName == TypeMetaFieldDef.name, schema.queryType?.name == parentType.name {
        return TypeMetaFieldDef
    } else if fieldName == TypeNameMetaFieldDef.name {
        return TypeNameMetaFieldDef
    }

    // This field should exist because we passed validation before execution
    guard let fieldDefinition = try parentType.getFields()[fieldName] else {
        throw GraphQLError(
            message: "Expected field definition not found: '\(fieldName)' on '\(parentType.name)'"
        )
    }
    return fieldDefinition
}
