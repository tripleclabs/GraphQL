
/**
 * Executable definitions
 *
 * A GraphQL document is only valid for execution if all definitions are either
 * operation or fragment definitions.
 *
 * See https://spec.graphql.org/draft/#sec-Executable-Definitions
 */
func ExecutableDefinitionsRule(context: ValidationContext) -> Visitor {
    return Visitor(
        enter: { node, _, _, _, _ in
            switch node.kind {
            case .document:
                let node = node as! Document
                for definition in node.definitions {
                    if !isExecutable(definition) {
                        var defName = "schema"
                        if let definition = definition as? TypeDefinition {
                            defName = "\"\(definition.name.value)\""
                        } else if let definition = definition as? TypeExtensionDefinition {
                            defName = "\"\(definition.definition.name.value)\""
                        }
                        context.report(
                            error: GraphQLError(
                                message: "The \(defName) definition is not executable.",
                                nodes: [definition]
                            )
                        )
                    }
                }
                return .continue
            default:
                return .continue
            }
        }
    )
}

func isExecutable(_ definition: Definition) -> Bool {
    definition.kind == .operationDefinition || definition
        .kind == .fragmentDefinition
}
