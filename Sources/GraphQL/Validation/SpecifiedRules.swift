/**
 * This set includes all validation rules defined by the GraphQL spec.
 */
public let specifiedRules: [@Sendable (ValidationContext) -> Visitor] = [
    ExecutableDefinitionsRule,
    UniqueOperationNamesRule,
    LoneAnonymousOperationRule,
//    SingleFieldSubscriptionsRule,
    KnownTypeNamesRule,
    FragmentsOnCompositeTypesRule,
    VariablesAreInputTypesRule,
    ScalarLeafsRule,
    FieldsOnCorrectTypeRule,
    UniqueFragmentNamesRule,
    KnownFragmentNamesRule,
    NoUnusedFragmentsRule,
    PossibleFragmentSpreadsRule,
    NoFragmentCyclesRule,
    UniqueVariableNamesRule,
    NoUndefinedVariablesRule,
    NoUnusedVariablesRule,
    KnownDirectivesRule,
    UniqueDirectivesPerLocationRule,
//    DeferStreamDirectiveOnRootFieldRule,
//    DeferStreamDirectiveOnValidOperationsRule,
//    DeferStreamDirectiveLabelRule,
    KnownArgumentNamesRule,
    UniqueArgumentNamesRule,
    ValuesOfCorrectTypeRule,
    ProvidedRequiredArgumentsRule,
    VariablesInAllowedPositionRule,
//    OverlappingFieldsCanBeMergedRule,
    UniqueInputFieldNamesRule,
]

/// Avoids invoking every spec-rule closure for every AST node when the document cannot possibly
/// contain the syntax that those rules inspect. A single cheap feature pass preserves the exact
/// rule implementations and error behavior while substantially reducing dispatch on hot queries.
func specifiedRules(
    for document: Document,
    schema: GraphQLSchema,
    recordVariableUsages: inout Bool
) -> [@Sendable (ValidationContext) -> Visitor] {
    var hasFragments = false
    var hasNamedFragments = false
    var hasFragmentSpreads = false
    var hasVariables = false
    var hasDirectives = false
    var hasArguments = false
    var hasInputObjects = false
    var hasInputLists = false
    var inlineTypeConditions: [String] = []

    func scan(value: Value) {
        if value is Variable { hasVariables = true }
        if let list = value as? ListValue {
            hasInputLists = true
            list.values.forEach(scan)
        } else if let object = value as? ObjectValue {
            hasInputObjects = true
            object.fields.forEach { scan(value: $0.value) }
        }
    }
    func scan(arguments: [Argument]) {
        if !arguments.isEmpty { hasArguments = true }
        arguments.forEach { scan(value: $0.value) }
    }
    func scan(directives: [Directive]) {
        if !directives.isEmpty { hasDirectives = true }
        directives.forEach { scan(arguments: $0.arguments) }
    }
    func scan(selectionSet: SelectionSet) {
        for selection in selectionSet.selections {
            if let field = selection as? Field {
                scan(arguments: field.arguments)
                scan(directives: field.directives)
                if let nested = field.selectionSet { scan(selectionSet: nested) }
            } else if let inlineFragment = selection as? InlineFragment {
                hasFragments = true
                if let condition = inlineFragment.typeCondition {
                    inlineTypeConditions.append(condition.name.value)
                }
                scan(directives: inlineFragment.directives)
                scan(selectionSet: inlineFragment.selectionSet)
            } else if let fragmentSpread = selection as? FragmentSpread {
                hasFragments = true
                hasFragmentSpreads = true
                scan(directives: fragmentSpread.directives)
            }
        }
    }
    for definition in document.definitions {
        if let operation = definition as? OperationDefinition {
            if !operation.variableDefinitions.isEmpty { hasVariables = true }
            for variable in operation.variableDefinitions {
                if let defaultValue = variable.defaultValue { scan(value: defaultValue) }
                scan(directives: variable.directives)
            }
            scan(directives: operation.directives)
            scan(selectionSet: operation.selectionSet)
        } else if let fragment = definition as? FragmentDefinition {
            hasFragments = true
            hasNamedFragments = true
            scan(directives: fragment.directives)
            scan(selectionSet: fragment.selectionSet)
        }
    }
    recordVariableUsages = hasVariables

    if !hasFragments, !hasVariables, !hasDirectives, !hasInputObjects, !hasInputLists {
        return [SimpleExecutableRules]
    }
    if hasFragments,
       !hasNamedFragments,
       !hasFragmentSpreads,
       !hasVariables,
       !hasDirectives,
       !hasInputObjects,
       !hasInputLists
    {
        let allTypeConditionsUnknown = !inlineTypeConditions.isEmpty &&
            inlineTypeConditions.allSatisfy { schema.getType(name: $0) == nil }
        if allTypeConditionsUnknown {
            return [SimpleExecutableRules, KnownTypeNamesRule]
        }
        return [
            SimpleExecutableRules,
            KnownTypeNamesRule,
            FragmentsOnCompositeTypesRule,
            PossibleFragmentSpreadsRule,
        ]
    }

    let hasTypes = hasFragments || hasVariables
    var rules: [@Sendable (ValidationContext) -> Visitor] = [
        ExecutableDefinitionsRule,
        UniqueOperationNamesRule,
        LoneAnonymousOperationRule,
    ]
    if hasTypes { rules.append(KnownTypeNamesRule) }
    if hasFragments {
        rules += [
            FragmentsOnCompositeTypesRule,
        ]
    }
    if hasVariables { rules.append(VariablesAreInputTypesRule) }
    rules += [ScalarLeafsRule, FieldsOnCorrectTypeRule]
    if hasFragments {
        rules += [
            UniqueFragmentNamesRule,
            KnownFragmentNamesRule,
            NoUnusedFragmentsRule,
            PossibleFragmentSpreadsRule,
            NoFragmentCyclesRule,
        ]
    }
    if hasVariables {
        rules += [
            UniqueVariableNamesRule,
            NoUndefinedVariablesRule,
            NoUnusedVariablesRule,
        ]
    }
    if hasDirectives {
        rules += [KnownDirectivesRule, UniqueDirectivesPerLocationRule]
    }
    if hasArguments {
        rules += [KnownArgumentNamesRule, UniqueArgumentNamesRule]
    }
    if hasArguments || hasVariables || hasDirectives { rules.append(ValuesOfCorrectTypeRule) }
    rules.append(ProvidedRequiredArgumentsRule)
    if hasVariables { rules.append(VariablesInAllowedPositionRule) }
    if hasInputObjects {
        rules.append(UniqueInputFieldNamesRule)
    }
    return rules
}

/// Fuses the rules needed by a plain field-selection document into one visitor. This avoids both
/// per-node dispatch across independent closures and the required-argument rule's construction of
/// an unused directive map on every request.
private func SimpleExecutableRules(context: ValidationContext) -> Visitor {
    var operationCount = 0
    var knownOperationNames: [String: Name] = [:]
    return Visitor(
        enter: { node, _, _, _, _ in
            if let document = node as? Document {
                operationCount = document.definitions.reduce(into: 0) { count, definition in
                    if definition is OperationDefinition { count += 1 }
                    if !isExecutable(definition) {
                        var definitionName = "schema"
                        if let definition = definition as? TypeDefinition {
                            definitionName = "\"\(definition.name.value)\""
                        } else if let definition = definition as? TypeExtensionDefinition {
                            definitionName = "\"\(definition.definition.name.value)\""
                        }
                        context.report(error: GraphQLError(
                            message: "The \(definitionName) definition is not executable.",
                            nodes: [definition]
                        ))
                    }
                }
            } else if let operation = node as? OperationDefinition {
                if let name = operation.name {
                    if let previous = knownOperationNames[name.value] {
                        context.report(error: GraphQLError(
                            message: "There can be only one operation named \"\(name.value)\".",
                            nodes: [previous, name]
                        ))
                    } else {
                        knownOperationNames[name.value] = name
                    }
                } else if operationCount > 1 {
                    context.report(error: GraphQLError(
                        message: "This anonymous operation must be the only defined operation.",
                        nodes: [operation]
                    ))
                }
            } else if let field = node as? Field {
                if let type = context.type {
                    if isLeafType(type: getNamedType(type: type)) {
                        if let selectionSet = field.selectionSet {
                            context.report(error: GraphQLError(
                                message: noSubselectionAllowedMessage(fieldName: field.name.value, type: type),
                                nodes: [selectionSet]
                            ))
                        }
                    } else if field.selectionSet == nil {
                        context.report(error: GraphQLError(
                            message: requiredSubselectionMessage(fieldName: field.name.value, type: type),
                            nodes: [field]
                        ))
                    }
                }

                if let parentType = context.parentType, context.fieldDef == nil {
                    let fieldName = field.name.value
                    let suggestedTypes = (try? getSuggestedTypeNames(
                        schema: context.schema,
                        type: parentType,
                        fieldName: fieldName
                    )) ?? []
                    let suggestedFields = suggestedTypes.isEmpty
                        ? getSuggestedFieldNames(
                            schema: context.schema,
                            type: parentType,
                            fieldName: fieldName
                        )
                        : []
                    context.report(error: GraphQLError(
                        message: undefinedFieldMessage(
                            fieldName: fieldName,
                            type: parentType.name,
                            suggestedTypeNames: suggestedTypes,
                            suggestedFieldNames: suggestedFields
                        ),
                        nodes: [field]
                    ))
                }

                if let parentType = context.parentType, let fieldDefinition = context.fieldDef {
                    var argumentsByName: [String: [Argument]] = [:]
                    for argument in field.arguments {
                        argumentsByName[argument.name.value, default: []].append(argument)
                        if !fieldDefinition.args.contains(where: { $0.name == argument.name.value }) {
                            let suggestions = getSuggestedArgumentNames(
                                schema: context.schema,
                                field: fieldDefinition,
                                argumentName: argument.name.value
                            )
                            context.report(error: GraphQLError(
                                message: undefinedArgumentMessage(
                                    fieldName: fieldDefinition.name,
                                    type: parentType.name,
                                    argumentName: argument.name.value,
                                    suggestedArgumentNames: suggestions
                                ),
                                nodes: [argument]
                            ))
                        }
                    }
                    for (name, arguments) in argumentsByName where arguments.count > 1 {
                        context.report(error: GraphQLError(
                            message: "There can be only one argument named \"\(name)\".",
                            nodes: arguments.map { $0.name }
                        ))
                    }
                }
            } else if let nullValue = node as? NullValue {
                if let inputType = context.inputType as? GraphQLNonNull {
                    context.report(error: GraphQLError(
                        message: "Expected value of type \"\(inputType)\", found \(print(ast: nullValue)).",
                        nodes: [nullValue]
                    ))
                }
            } else if let value = node as? Value {
                switch value.kind {
                case .enumValue, .intValue, .floatValue, .stringValue, .booleanValue:
                    isValidValueNode(context, value)
                default:
                    break
                }
            }
            return .continue
        },
        leave: { node, _, _, _, _ in
            if let field = node as? Field, let fieldDefinition = context.fieldDef {
                let provided = Set(field.arguments.map { $0.name.value })
                for argument in fieldDefinition.args
                    where isRequiredArgument(argument) && !provided.contains(argument.name)
                {
                    context.report(error: GraphQLError(
                        message: "Field \"\(fieldDefinition.name)\" argument \"\(argument.name)\" of type \"\(argument.type)\" is required, but it was not provided.",
                        nodes: [field]
                    ))
                }
            }
            return .continue
        }
    )
}

/**
 * @internal
 */
public let specifiedSDLRules: [SDLValidationRule] = [
    LoneSchemaDefinitionRule,
    UniqueOperationTypesRule,
    UniqueTypeNamesRule,
    UniqueEnumValueNamesRule,
    UniqueFieldDefinitionNamesRule,
    UniqueArgumentDefinitionNamesRule,
    UniqueDirectiveNamesRule,
    KnownTypeNamesRule,
    KnownDirectivesRule,
    UniqueDirectivesPerLocationRule,
    PossibleTypeExtensionsRule,
    KnownArgumentNamesOnDirectivesRule,
    UniqueArgumentNamesRule,
    UniqueInputFieldNamesRule,
    ProvidedRequiredArgumentsOnDirectivesRule,
]
