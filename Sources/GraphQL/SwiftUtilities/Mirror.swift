func unwrap(_ value: any Sendable) -> (any Sendable)? {
    let mirror = Mirror(reflecting: value)

    if mirror.displayStyle != .optional {
        return value
    }

    guard let child = mirror.children.first else {
        return nil
    }

    return assumeSendable(child.value)
}

extension Mirror {
    func getValue(named key: String) -> (any Sendable)? {
        guard let matched = children.first(where: { $0.label == key }) else {
            return nil
        }

        // `Mirror.Child` erases the property's static type to `Any`. The source value entered
        // GraphQL through a Sendable resolver boundary, so its reflected stored properties must
        // uphold that same contract.
        return unwrap(assumeSendable(matched.value))
    }
}
