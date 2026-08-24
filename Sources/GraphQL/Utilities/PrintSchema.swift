import Foundation

/// Renders a schema as SDL.
///
/// - Parameter appliedDirectives: Directives to render at schema locations,
///   keyed by path. Applied directives are not stored on the schema's type
///   objects, so they must be supplied here — omitting them (as the
///   single-argument call does) yields SDL with no applied directives.
public func printSchema(
    schema: GraphQLSchema,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String {
    return printFilteredSchema(
        schema: schema,
        directiveFilter: { n in !isSpecifiedDirective(n) },
        typeFilter: isDefinedType,
        appliedDirectives: appliedDirectives
    )
}

/// Renders the introspection schema as SDL.
///
/// - Note: Never renders applied directives; introspection types cannot carry
///   user-supplied directives.
public func printIntrospectionSchema(schema: GraphQLSchema) -> String {
    return printFilteredSchema(
        schema: schema,
        directiveFilter: isSpecifiedDirective,
        typeFilter: isIntrospectionType,
        appliedDirectives: [:]
    )
}

func isDefinedType(type: GraphQLNamedType) -> Bool {
    return !isSpecifiedScalarType(type) && !isIntrospectionType(type: type)
}

func printFilteredSchema(
    schema: GraphQLSchema,
    directiveFilter: (GraphQLDirective) -> Bool,
    typeFilter: (GraphQLNamedType) -> Bool,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String {
    let directives = schema.directives.filter { directiveFilter($0) }
    let types = schema.typeMap.values.filter { typeFilter($0) }

    var result = [printSchemaDefinition(schema: schema, appliedDirectives: appliedDirectives)]
    result.append(contentsOf: directives.map { printDirective(directive: $0) })
    result.append(contentsOf: types.map {
        printType(type: $0, appliedDirectives: appliedDirectives, schema: schema)
    })

    return result.compactMap { $0 }
        .joined(separator: "\n\n")
}

func printSchemaDefinition(
    schema: GraphQLSchema,
    appliedDirectives: AppliedDirectiveMap = [:]
) -> String? {
    let queryType = schema.queryType
    let mutationType = schema.mutationType
    let subscriptionType = schema.subscriptionType

    // Special case: When a schema has no root operation types, no valid schema
    // definition can be printed.
    if queryType == nil, mutationType == nil, subscriptionType == nil {
        return nil
    }

    let directives = printAppliedDirectives(.schema, appliedDirectives, schema)

    // Only print a schema definition if there is a description, an applied
    // directive that would otherwise be lost, or if it should not be omitted
    // because of having default type names.
    if schema.description != nil || !directives.isEmpty ||
        !hasDefaultRootOperationTypes(schema: schema)
    {
        var result = printDescription(schema.description) +
            "schema" + directives + " {\n"
        if let queryType = queryType {
            result = result + "  query: \(queryType.name)\n"
        }
        if let mutationType = mutationType {
            result = result + "  mutation: \(mutationType.name)\n"
        }
        if let subscriptionType = subscriptionType {
            result = result + "  subscription: \(subscriptionType.name)\n"
        }
        result = result + "}"
        return result
    }
    return nil
}

/**
 * GraphQL schema define root types for each type of operation. These types are
 * the same as any other type and can be named in any manner, however there is
 * a common naming convention:
 *
 * ```graphql
 *   schema {
 *     query: Query
 *     mutation: Mutation
 *     subscription: Subscription
 *   }
 * ```
 *
 * When using this naming convention, the schema description can be omitted so
 * long as these names are only used for operation types.
 *
 * Note however that if any of these default names are used elsewhere in the
 * schema but not as a root operation type, the schema definition must still
 * be printed to avoid ambiguity.
 */
func hasDefaultRootOperationTypes(schema: GraphQLSchema) -> Bool {
    // The goal here is to check if a type was declared using the default names of "Query",
    // "Mutation" or "Subscription". We do so by comparing object IDs to determine if the
    // schema operation object is the same as the type object by that name.
    return (
        schema.queryType.map { ObjectIdentifier($0) }
            == (schema.getType(name: "Query") as? GraphQLObjectType).map { ObjectIdentifier($0) } &&
            schema.mutationType.map { ObjectIdentifier($0) }
            == (schema.getType(name: "Mutation") as? GraphQLObjectType)
            .map { ObjectIdentifier($0) } &&
            schema.subscriptionType.map { ObjectIdentifier($0) }
            == (schema.getType(name: "Subscription") as? GraphQLObjectType)
            .map { ObjectIdentifier($0) }
    )
}

/// Renders a single named type as SDL.
///
/// - Note: Never renders applied directives — a lone type carries no schema to
///   resolve them against. Use `printSchema(schema:appliedDirectives:)` for
///   directive-annotated output.
public func printType(type: GraphQLNamedType) -> String {
    return printType(type: type, appliedDirectives: [:], schema: nil)
}

func printType(
    type: GraphQLNamedType,
    appliedDirectives: AppliedDirectiveMap,
    schema: GraphQLSchema?
) -> String {
    let directives: String = {
        guard let schema = schema else { return "" }
        return printAppliedDirectives(.type(type.name), appliedDirectives, schema)
    }()

    if let type = type as? GraphQLScalarType {
        return printScalar(type: type, directives: directives)
    }
    if let type = type as? GraphQLObjectType {
        return printObject(
            type: type,
            directives: directives,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
    }
    if let type = type as? GraphQLInterfaceType {
        return printInterface(
            type: type,
            directives: directives,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
    }
    if let type = type as? GraphQLUnionType {
        return printUnion(type: type, directives: directives)
    }
    if let type = type as? GraphQLEnumType {
        return printEnum(
            type: type,
            directives: directives,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
    }
    if let type = type as? GraphQLInputObjectType {
        return printInputObject(
            type: type,
            directives: directives,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
    }

    // Not reachable, all possible types have been considered.
    fatalError("Unexpected type: " + type.name)
}

func printScalar(type: GraphQLScalarType, directives: String = "") -> String {
    return printDescription(type.description) +
        "scalar \(type.name)" +
        printSpecifiedByURL(scalar: type) +
        directives
}

func printImplementedInterfaces(
    interfaces: [GraphQLInterfaceType]
) -> String {
    return interfaces.isEmpty
        ? ""
        : " implements " + interfaces.map { $0.name }.joined(separator: " & ")
}

func printObject(
    type: GraphQLObjectType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    return
        printDescription(type.description) +
        "type \(type.name)" +
        printImplementedInterfaces(interfaces: (try? type.getInterfaces()) ?? []) +
        directives +
        printFields(
            fields: (try? type.getFields()) ?? [:],
            typeName: type.name,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
}

func printInterface(
    type: GraphQLInterfaceType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    return
        printDescription(type.description) +
        "interface \(type.name)" +
        printImplementedInterfaces(interfaces: (try? type.getInterfaces()) ?? []) +
        directives +
        printFields(
            fields: (try? type.getFields()) ?? [:],
            typeName: type.name,
            appliedDirectives: appliedDirectives,
            schema: schema
        )
}

func printUnion(type: GraphQLUnionType, directives: String = "") -> String {
    let types = (try? type.getTypes()) ?? []
    return
        printDescription(type.description) +
        "union \(type.name)" +
        directives +
        (types.isEmpty ? "" : " = " + types.map { $0.name }.joined(separator: " | "))
}

func printEnum(
    type: GraphQLEnumType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    let values = type.values.enumerated().map { i, value in
        let valueDirectives: String = {
            guard let schema = schema else { return "" }
            return printAppliedDirectives(
                .member(type: type.name, member: value.name),
                appliedDirectives,
                schema
            )
        }()

        return printDescription(value.description, indentation: "  ", firstInBlock: i == 0) +
            "  " +
            value.name +
            printDeprecated(reason: value.deprecationReason) +
            valueDirectives
    }

    return printDescription(type.description) + "enum \(type.name)" + directives +
        printBlock(items: values)
}

func printInputObject(
    type: GraphQLInputObjectType,
    directives: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    let inputFields = (try? type.getFields()) ?? [:]
    let fields = inputFields.values.enumerated().map { i, f in
        let fieldDirectives: String = {
            guard let schema = schema else { return "" }
            return printAppliedDirectives(
                .member(type: type.name, member: f.name),
                appliedDirectives,
                schema
            )
        }()

        return printDescription(f.description, indentation: "  ", firstInBlock: i == 0) + "  " +
            printInputValue(arg: f) + fieldDirectives
    }

    return
        printDescription(type.description) +
        "input \(type.name)" +
        (type.isOneOf ? " @oneOf" : "") +
        directives +
        printBlock(items: fields)
}

func printFields(
    fields: GraphQLFieldDefinitionMap,
    typeName: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    let fields = fields.values.enumerated().map { i, f in
        let fieldDirectives: String = {
            guard let schema = schema else { return "" }
            return printAppliedDirectives(
                .member(type: typeName, member: f.name),
                appliedDirectives,
                schema
            )
        }()

        return printDescription(f.description, indentation: "  ", firstInBlock: i == 0) +
            "  " +
            f.name +
            printArgs(
                args: f.args,
                indentation: "  ",
                typeName: typeName,
                fieldName: f.name,
                appliedDirectives: appliedDirectives,
                schema: schema
            ) +
            ": " +
            f.type.debugDescription +
            printDeprecated(reason: f.deprecationReason) +
            fieldDirectives
    }
    return printBlock(items: fields)
}

func printBlock(items: [String]) -> String {
    return items.isEmpty ? "" : " {\n" + items.joined(separator: "\n") + "\n}"
}

func printArgs(
    args: [GraphQLArgumentDefinition],
    indentation: String = "",
    typeName: String = "",
    fieldName: String = "",
    appliedDirectives: AppliedDirectiveMap = [:],
    schema: GraphQLSchema? = nil
) -> String {
    if args.isEmpty {
        return ""
    }

    func directives(for arg: GraphQLArgumentDefinition) -> String {
        guard let schema = schema else { return "" }
        return printAppliedDirectives(
            .argument(type: typeName, field: fieldName, argument: arg.name),
            appliedDirectives,
            schema
        )
    }

    // If every arg does not have a description, print them on one line.
    if args.allSatisfy({ $0.description == nil }) {
        return "(" + args.map { printArgValue(arg: $0) + directives(for: $0) }
            .joined(separator: ", ") + ")"
    }

    return
        "(\n" +
        args.enumerated().map { i, arg in
            printDescription(
                arg.description,
                indentation: "  " + indentation,
                firstInBlock: i == 0
            ) +
                "  " +
                indentation +
                printArgValue(arg: arg) +
                directives(for: arg)
        }.joined(separator: "\n") +
        "\n" +
        indentation +
        ")"
}

func printArgValue(arg: GraphQLArgumentDefinition) -> String {
    var argDecl = arg.name + ": " + arg.type.debugDescription
    if let defaultValue = arg.defaultValue {
        if defaultValue == .null {
            argDecl = argDecl + " = null"
        } else if let defaultAST = try! astFromValue(value: defaultValue, type: arg.type) {
            argDecl = argDecl + " = \(print(ast: defaultAST))"
        }
    }
    return argDecl + printDeprecated(reason: arg.deprecationReason)
}

func printInputValue(arg: InputObjectFieldDefinition) -> String {
    var argDecl = arg.name + ": " + arg.type.debugDescription
    if let defaultAST = try? astFromValue(value: arg.defaultValue ?? .null, type: arg.type) {
        argDecl = argDecl + " = \(print(ast: defaultAST))"
    }
    return argDecl + printDeprecated(reason: arg.deprecationReason)
}

public func printDirective(directive: GraphQLDirective) -> String {
    return
        printDescription(directive.description) +
        "directive @" +
        directive.name +
        printArgs(args: directive.args) +
        (directive.isRepeatable ? " repeatable" : "") +
        " on " +
        directive.locations.map { $0.rawValue }.joined(separator: " | ")
}

func printDeprecated(reason: String?) -> String {
    guard let reason = reason else {
        return ""
    }
    if reason != defaultDeprecationReason {
        let astValue = print(ast: StringValue(value: reason))
        return " @deprecated(reason: \(astValue))"
    }
    return " @deprecated"
}

func printSpecifiedByURL(scalar: GraphQLScalarType) -> String {
    guard let specifiedByURL = scalar.specifiedByURL else {
        return ""
    }
    let astValue = StringValue(value: specifiedByURL)
    return " @specifiedBy(url: \"\(astValue.value)\")"
}

func printDescription(
    _ description: String?,
    indentation: String = "",
    firstInBlock: Bool = true
) -> String {
    guard let description = description else {
        return ""
    }

    let blockString = print(ast: StringValue(
        value: description,
        block: isPrintableAsBlockString(description)
    ))

    let prefix = (!indentation.isEmpty && !firstInBlock) ? "\n" + indentation : indentation

    return prefix + blockString.replacingOccurrences(of: "\n", with: "\n" + indentation) + "\n"
}
