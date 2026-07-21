private protocol OptionalValue {
    var wrappedValue: Any? { get }
}

extension Optional: OptionalValue {
    fileprivate var wrappedValue: Any? {
        self
    }
}

func unwrap(_ value: any Sendable) -> (any Sendable)? {
    if let optional = value as? any OptionalValue {
        return optional.wrappedValue.map(assumeSendable)
    }

    return value
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
