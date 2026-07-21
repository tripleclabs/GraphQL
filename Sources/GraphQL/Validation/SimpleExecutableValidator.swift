/// Validates the common single-operation, field-only document shape without constructing a
/// TypeInfo-driven visitor graph. Returning `nil` asks the general validator to handle syntax this
/// deliberately small fast path does not support.
func validateSimpleExecutableDocument(
    schema: GraphQLSchema,
    document: Document
) -> [GraphQLError]? {
    guard document.definitions.count == 1,
          let operation = document.definitions[0] as? OperationDefinition,
          operation.variableDefinitions.isEmpty,
          operation.directives.isEmpty,
          let rootType = try? getOperationRootType(schema: schema, operation: operation)
    else {
        return nil
    }

    var errors: [GraphQLError] = []
    var supported = true

    func validateLiteral(_ value: Value, type: GraphQLInputType) {
        if value is Variable || value is ListValue || value is ObjectValue {
            supported = false
            return
        }
        if value is NullValue {
            if type is GraphQLNonNull {
                errors.append(GraphQLError(
                    message: "Expected value of type \"\(type)\", found \(print(ast: value)).",
                    nodes: [value]
                ))
            }
            return
        }

        let namedType = getNamedType(type: type)
        guard isLeafType(type: namedType) else {
            errors.append(GraphQLError(
                message: "Expected value of type \"\(type)\", found \(print(ast: value)).",
                nodes: [value]
            ))
            return
        }
        do {
            let parsed: Map
            if let scalar = namedType as? GraphQLScalarType {
                parsed = try scalar.parseLiteral(valueAST: value)
            } else if let enumType = namedType as? GraphQLEnumType {
                parsed = try enumType.parseLiteral(valueAST: value)
            } else {
                return
            }
            if parsed == .undefined {
                errors.append(GraphQLError(
                    message: "Expected value of type \"\(type)\", found \(print(ast: value)).",
                    nodes: [value]
                ))
            }
        } catch let error as GraphQLError {
            errors.append(error)
        } catch {
            errors.append(GraphQLError(
                message: "Expected value of type \"\(type)\", found \(print(ast: value)).",
                nodes: [value]
            ))
        }
    }

    func validateSelectionSet(_ selectionSet: SelectionSet, parentType: GraphQLObjectType) {
        for selection in selectionSet.selections {
            guard let field = selection as? Field, field.directives.isEmpty else {
                supported = false
                continue
            }

            let fieldName = field.name.value
            guard let fieldDefinition = try? getFieldDef(
                schema: schema,
                parentType: parentType,
                fieldName: fieldName
            ) else {
                let suggestedTypes = (try? getSuggestedTypeNames(
                    schema: schema,
                    type: parentType,
                    fieldName: fieldName
                )) ?? []
                let suggestedFields = suggestedTypes.isEmpty
                    ? getSuggestedFieldNames(
                        schema: schema,
                        type: parentType,
                        fieldName: fieldName
                    )
                    : []
                errors.append(GraphQLError(
                    message: undefinedFieldMessage(
                        fieldName: fieldName,
                        type: parentType.name,
                        suggestedTypeNames: suggestedTypes,
                        suggestedFieldNames: suggestedFields
                    ),
                    nodes: [field]
                ))
                continue
            }

            var argumentsByName: [String: [Argument]] = [:]
            for argument in field.arguments {
                argumentsByName[argument.name.value, default: []].append(argument)
                guard let argumentDefinition = fieldDefinition.args.first(where: {
                    $0.name == argument.name.value
                }) else {
                    let suggestions = getSuggestedArgumentNames(
                        schema: schema,
                        field: fieldDefinition,
                        argumentName: argument.name.value
                    )
                    errors.append(GraphQLError(
                        message: undefinedArgumentMessage(
                            fieldName: fieldDefinition.name,
                            type: parentType.name,
                            argumentName: argument.name.value,
                            suggestedArgumentNames: suggestions
                        ),
                        nodes: [argument]
                    ))
                    continue
                }
                validateLiteral(argument.value, type: argumentDefinition.type)
            }
            for (_, duplicateArguments) in argumentsByName where duplicateArguments.count > 1 {
                let name = duplicateArguments[0].name.value
                errors.append(GraphQLError(
                    message: "There can be only one argument named \"\(name)\".",
                    nodes: duplicateArguments.map { $0.name }
                ))
            }
            for argument in fieldDefinition.args
                where isRequiredArgument(argument) && argumentsByName[argument.name] == nil
            {
                errors.append(GraphQLError(
                    message: "Field \"\(fieldDefinition.name)\" argument \"\(argument.name)\" of type \"\(argument.type)\" is required, but it was not provided.",
                    nodes: [field]
                ))
            }

            let namedOutputType = getNamedType(type: fieldDefinition.type)
            if isLeafType(type: namedOutputType) {
                if let childSelectionSet = field.selectionSet {
                    errors.append(GraphQLError(
                        message: noSubselectionAllowedMessage(
                            fieldName: fieldName,
                            type: fieldDefinition.type
                        ),
                        nodes: [childSelectionSet]
                    ))
                }
            } else if let objectType = namedOutputType as? GraphQLObjectType {
                guard let childSelectionSet = field.selectionSet else {
                    errors.append(GraphQLError(
                        message: requiredSubselectionMessage(
                            fieldName: fieldName,
                            type: fieldDefinition.type
                        ),
                        nodes: [field]
                    ))
                    continue
                }
                validateSelectionSet(childSelectionSet, parentType: objectType)
            } else {
                // Abstract output types require fragment-aware validation.
                supported = false
            }
        }
    }

    validateSelectionSet(operation.selectionSet, parentType: rootType)
    return supported ? errors : nil
}
