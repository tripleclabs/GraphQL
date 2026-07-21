@frozen
public struct FastSchemaTypeID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

@frozen
public struct FastSchemaFieldID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

@frozen
public struct FastSchemaTypeReferenceID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

@frozen
public struct FastSchemaNameID: Sendable, Hashable, RawRepresentable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }
}

@frozen
public struct FastSchemaRoots: Sendable {
    public let query: FastSchemaTypeID?
    public let mutation: FastSchemaTypeID?
    public let subscription: FastSchemaTypeID?

    @inlinable
    public init(
        query: FastSchemaTypeID?,
        mutation: FastSchemaTypeID?,
        subscription: FastSchemaTypeID?
    ) {
        self.query = query
        self.mutation = mutation
        self.subscription = subscription
    }
}

@frozen
public struct FastSchemaType: Sendable {
    public enum Kind: UInt8, Sendable {
        case scalar
        case object
        case interface
        case union
        case `enum`
        case inputObject
    }

    public let kind: Kind
    public let name: FastSchemaNameID
    public let fields: FastArenaRange
    public let inputFields: FastArenaRange

    @inlinable
    public init(
        kind: Kind,
        name: FastSchemaNameID,
        fields: FastArenaRange,
        inputFields: FastArenaRange
    ) {
        self.kind = kind
        self.name = name
        self.fields = fields
        self.inputFields = inputFields
    }
}

@frozen
public struct FastSchemaTypeReference: Sendable {
    public enum Kind: UInt8, Sendable {
        case named
        case list
        case nonNull
    }

    public let kind: Kind
    public let namedType: FastSchemaTypeID
    public let wrappedType: FastSchemaTypeReferenceID?

    @inlinable
    public init(
        kind: Kind,
        namedType: FastSchemaTypeID,
        wrappedType: FastSchemaTypeReferenceID?
    ) {
        self.kind = kind
        self.namedType = namedType
        self.wrappedType = wrappedType
    }
}

@frozen
public struct FastSchemaField: Sendable {
    public let parentType: FastSchemaTypeID
    public let name: FastSchemaNameID
    public let type: FastSchemaTypeReferenceID
    public let arguments: FastArenaRange
    public let isDeprecated: Bool

    @inlinable
    public init(
        parentType: FastSchemaTypeID,
        name: FastSchemaNameID,
        type: FastSchemaTypeReferenceID,
        arguments: FastArenaRange,
        isDeprecated: Bool
    ) {
        self.parentType = parentType
        self.name = name
        self.type = type
        self.arguments = arguments
        self.isDeprecated = isDeprecated
    }
}

@frozen
public struct FastSchemaInputValue: Sendable {
    public let name: FastSchemaNameID
    public let type: FastSchemaTypeReferenceID
    public let hasDefaultValue: Bool
    public let isDeprecated: Bool

    @inlinable
    public init(
        name: FastSchemaNameID,
        type: FastSchemaTypeReferenceID,
        hasDefaultValue: Bool,
        isDeprecated: Bool
    ) {
        self.name = name
        self.type = type
        self.hasDefaultValue = hasDefaultValue
        self.isDeprecated = isDeprecated
    }
}

/// Immutable numeric metadata compiled once from the authoritative public schema.
public struct FastCompiledSchema: Sendable {
    public let names: ContiguousArray<String>
    public let types: ContiguousArray<FastSchemaType>
    public let typeReferences: ContiguousArray<FastSchemaTypeReference>
    public let fields: ContiguousArray<FastSchemaField>
    public let inputValues: ContiguousArray<FastSchemaInputValue>
    public let roots: FastSchemaRoots

    private let nameLookup: [String: FastSchemaNameID]
    private let typeLookup: [String: FastSchemaTypeID]
    private let fieldLookup: [FieldLookupKey: FastSchemaFieldID]

    public init(
        names: ContiguousArray<String>,
        types: ContiguousArray<FastSchemaType>,
        typeReferences: ContiguousArray<FastSchemaTypeReference>,
        fields: ContiguousArray<FastSchemaField>,
        inputValues: ContiguousArray<FastSchemaInputValue>,
        roots: FastSchemaRoots
    ) {
        self.names = names
        self.types = types
        self.typeReferences = typeReferences
        self.fields = fields
        self.inputValues = inputValues
        self.roots = roots

        var namesByValue: [String: FastSchemaNameID] = [:]
        namesByValue.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            namesByValue[name] = FastSchemaNameID(rawValue: UInt32(index))
        }
        nameLookup = namesByValue

        var typesByName: [String: FastSchemaTypeID] = [:]
        typesByName.reserveCapacity(types.count)
        for (index, type) in types.enumerated() {
            typesByName[names[Int(type.name.rawValue)]] = FastSchemaTypeID(rawValue: UInt32(index))
        }
        typeLookup = typesByName

        var fieldsByParentAndName: [FieldLookupKey: FastSchemaFieldID] = [:]
        fieldsByParentAndName.reserveCapacity(fields.count)
        for (index, field) in fields.enumerated() {
            fieldsByParentAndName[FieldLookupKey(parent: field.parentType, name: field.name)] =
                FastSchemaFieldID(rawValue: UInt32(index))
        }
        fieldLookup = fieldsByParentAndName
    }

    @inlinable
    public func name(_ id: FastSchemaNameID) -> String {
        names[Int(id.rawValue)]
    }

    public func typeID(named name: String) -> FastSchemaTypeID? {
        typeLookup[name]
    }

    public func fieldID(
        on parent: FastSchemaTypeID,
        named name: String
    ) -> FastSchemaFieldID? {
        guard let name = nameLookup[name] else { return nil }
        return fieldLookup[FieldLookupKey(parent: parent, name: name)]
    }
}

private struct FieldLookupKey: Sendable, Hashable {
    let parent: FastSchemaTypeID
    let name: FastSchemaNameID
}
