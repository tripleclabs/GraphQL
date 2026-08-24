/**
 * Subscriptions must only include a non-introspection field
 *
 * A GraphQL subscription is valid only if it contains a single root field, and
 * that field is not an introspection field.
 *
 * Field collection for subscriptions has no access to variable values, so
 * whether an operation is valid must not depend on them. The `@skip` and
 * `@include` directives are therefore forbidden in the root selection set
 * rather than evaluated.
 *
 * See https://spec.graphql.org/draft/#sec-Single-root-field
 */
func SingleFieldSubscriptionsRule(context: ValidationContext) -> Visitor {
    return Visitor(
        enter: { node, _, _, _, _ in
            guard
                let operation = node as? OperationDefinition,
                operation.operation == .subscription
            else {
                return .continue
            }

            let subject = operation.name
                .map { "Subscription \"\($0.value)\"" } ?? "Anonymous Subscription"

            if selectionSetUsesConditionalDirectives(operation.selectionSet) {
                context.report(
                    error: GraphQLError(
                        message: "\(subject) must not provide the @skip or @include directive on its root selection set.",
                        nodes: [operation]
                    )
                )
                return .continue
            }

            var fieldNames: Set<String> = []
            collectSubscriptionFields(
                operation.selectionSet,
                context: context,
                visitedFragments: [],
                into: &fieldNames
            )

            if fieldNames.count > 1 {
                context.report(
                    error: GraphQLError(
                        message: "\(subject) must select only one field.",
                        nodes: [operation]
                    )
                )
                return .continue
            }

            if let only = fieldNames.first, only.hasPrefix("__") {
                context.report(
                    error: GraphQLError(
                        message: "\(subject) must not select an introspection top level field.",
                        nodes: [operation]
                    )
                )
            }

            return .continue
        }
    )
}

/// Whether any selection directly in this set carries `@skip` or `@include`.
private func selectionSetUsesConditionalDirectives(_ selectionSet: SelectionSet) -> Bool {
    for selection in selectionSet.selections {
        let directives: [Directive]
        switch selection {
        case let field as Field:
            directives = field.directives
        case let spread as FragmentSpread:
            directives = spread.directives
        case let inlineFragment as InlineFragment:
            directives = inlineFragment.directives
        default:
            directives = []
        }

        if directives.contains(where: { $0.name.value == "skip" || $0.name.value == "include" }) {
            return true
        }
    }
    return false
}

/// The response keys a subscription's root selection set collects to, expanding
/// fragments. Mirrors CollectSubscriptionFields, which unlike normal field
/// collection has no variable values available.
private func collectSubscriptionFields(
    _ selectionSet: SelectionSet,
    context: ValidationContext,
    visitedFragments: Set<String>,
    into fieldNames: inout Set<String>
) {
    var visitedFragments = visitedFragments

    for selection in selectionSet.selections {
        switch selection {
        case let field as Field:
            fieldNames.insert(field.alias?.value ?? field.name.value)
        case let spread as FragmentSpread:
            let name = spread.name.value
            guard !visitedFragments.contains(name) else {
                continue
            }
            visitedFragments.insert(name)
            if let fragment = context.getFragment(name: name) {
                collectSubscriptionFields(
                    fragment.selectionSet,
                    context: context,
                    visitedFragments: visitedFragments,
                    into: &fieldNames
                )
            }
        case let inlineFragment as InlineFragment:
            collectSubscriptionFields(
                inlineFragment.selectionSet,
                context: context,
                visitedFragments: visitedFragments,
                into: &fieldNames
            )
        default:
            continue
        }
    }
}
