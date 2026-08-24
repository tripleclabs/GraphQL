/// Identifies a location in a schema where directives may be applied.
///
/// Named types are unique schema-wide, so a single `type` case covers objects,
/// interfaces, unions, enums, input objects and scalars. A single `member` case
/// covers object fields, input fields and enum values.
public enum DirectiveTarget: Hashable, Sendable {
    case schema
    case type(String)
    case member(type: String, member: String)
    case argument(type: String, field: String, argument: String)
}

/// A directive applied to a schema location, to be rendered into SDL.
///
/// Arguments are ordered pairs rather than a dictionary so that emitted SDL is
/// byte-stable across builds.
public struct AppliedDirective: Sendable {
    public let name: String
    public let arguments: [(String, Map)]

    public init(name: String, arguments: [(String, Map)] = []) {
        self.name = name
        self.arguments = arguments
    }
}

public typealias AppliedDirectiveMap = [DirectiveTarget: [AppliedDirective]]

/// Builds a `Directive` AST node from an applied directive, resolving argument
/// values against the declared argument types so enums render unquoted.
///
/// Returns nil when the directive is not declared in the schema. Callers of the
/// public print API may pass anything, so this skips rather than traps.
func directiveNode(
    from applied: AppliedDirective,
    schema: GraphQLSchema
) -> Directive? {
    guard let definition = schema.directives.first(where: { $0.name == applied.name }) else {
        return nil
    }

    var arguments: [Argument] = []
    for (argName, argValue) in applied.arguments {
        guard let argDefinition = definition.args.first(where: { $0.name == argName }) else {
            continue
        }
        guard let valueNode = try? astFromValue(value: argValue, type: argDefinition.type) else {
            continue
        }
        arguments.append(Argument(name: Name(value: argName), value: valueNode))
    }

    return Directive(name: Name(value: applied.name), arguments: arguments)
}

/// Renders the directives applied at `target` as a space-prefixed SDL fragment,
/// or the empty string when there are none.
func printAppliedDirectives(
    _ target: DirectiveTarget,
    _ map: AppliedDirectiveMap,
    _ schema: GraphQLSchema
) -> String {
    guard let applied = map[target], !applied.isEmpty else {
        return ""
    }

    let printed = applied
        .compactMap { directiveNode(from: $0, schema: schema) }
        .map { print(ast: $0) }

    return printed.isEmpty ? "" : " " + printed.joined(separator: " ")
}

/// Returns a human-readable error for each argument value that will not coerce
/// to its declared type, or an empty array when every value is valid.
///
/// This lives here because `astFromValue` is internal to this module; callers
/// outside it (such as Graphiti's schema validation) cannot perform the check
/// themselves. Arguments not present on the definition are ignored — the caller
/// is expected to reject unknown argument names separately.
public func coercionErrors(
    for applied: AppliedDirective,
    against definition: GraphQLDirective
) -> [String] {
    var errors: [String] = []

    for (argName, argValue) in applied.arguments {
        guard let argDefinition = definition.args.first(where: { $0.name == argName }) else {
            continue
        }
        let node = try? astFromValue(value: argValue, type: argDefinition.type)
        if node == nil {
            errors.append(
                "Value for argument \(argName) of directive @\(applied.name) does not coerce to \(argDefinition.type)."
            )
        }
    }

    return errors
}
