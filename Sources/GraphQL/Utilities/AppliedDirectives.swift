/// Identifies a location in a schema where directives may be applied.
///
/// Named types are unique schema-wide, so a single `type` case covers objects,
/// interfaces, unions, enums, input objects and scalars. A single `member` case
/// covers object fields, input fields and enum values.
/// - Note: Arguments of a *directive definition* are not addressable. The
///   `argument` case identifies an argument of a field on a named type;
///   `printDirective` renders definitions without consulting applied directives.
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

extension AppliedDirective: Equatable {
    // Synthesis is unavailable because `arguments` is an array of tuples.
    public static func == (lhs: AppliedDirective, rhs: AppliedDirective) -> Bool {
        lhs.name == rhs.name &&
            lhs.arguments.count == rhs.arguments.count &&
            zip(lhs.arguments, rhs.arguments).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

public typealias AppliedDirectiveMap = [DirectiveTarget: [AppliedDirective]]

/// Builds a `Directive` AST node from an applied directive, resolving argument
/// values against the declared argument types so enums render unquoted.
///
/// Returns nil — skipping the directive entirely — when it is not declared in
/// the schema, when it names an argument the declaration does not have, or when
/// an argument value will not coerce to its declared type. Emitting a directive
/// that had silently lost an argument would produce SDL that parses but means
/// something different, so the whole directive is dropped instead. Callers of
/// the public print API may pass anything, so this skips rather than traps;
/// Graphiti rejects all three cases at schema-build time.
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
            return nil
        }

        // astFromValue returns nil for null as a success, so an explicit null
        // has to be turned into a NullValue node rather than treated as failure.
        if argValue == .null {
            guard !(argDefinition.type is GraphQLNonNull) else {
                return nil
            }
            arguments.append(Argument(name: Name(value: argName), value: NullValue()))
            continue
        }

        guard let valueNode = try? astFromValue(value: argValue, type: argDefinition.type) else {
            return nil
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

public extension AppliedDirective {
    /// Returns a human-readable error for each argument value that will not
    /// coerce to its declared type, or an empty array when every value is valid.
    ///
    /// This lives in this module because `astFromValue` is internal to it;
    /// callers outside (such as Graphiti's schema validation) cannot perform the
    /// check themselves. Arguments not present on the definition are ignored —
    /// the caller is expected to reject unknown argument names separately.
    func coercionErrors(against definition: GraphQLDirective) -> [String] {
        var errors: [String] = []

        for (argName, argValue) in arguments {
            guard let argDefinition = definition.args.first(where: { $0.name == argName }) else {
                continue
            }

            // astFromValue returns nil for null as a success, so null is only an
            // error when the declared argument type forbids it.
            if argValue == .null {
                if argDefinition.type is GraphQLNonNull {
                    errors.append(
                        "Argument \(argName) of directive @\(name) is non-null but was given null."
                    )
                }
                continue
            }

            let node = try? astFromValue(value: argValue, type: argDefinition.type)
            if node == nil {
                errors.append(
                    "Value for argument \(argName) of directive @\(name) does not coerce to \(argDefinition.type)."
                )
            }
        }

        return errors
    }
}
