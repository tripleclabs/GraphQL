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
public struct FastSchemaDirectiveID: Sendable, Hashable, RawRepresentable {
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
    public let interfaces: FastArenaRange
    public let possibleTypes: FastArenaRange
    public let enumValues: FastArenaRange

    @inlinable
    public init(
        kind: Kind,
        name: FastSchemaNameID,
        fields: FastArenaRange,
        inputFields: FastArenaRange,
        interfaces: FastArenaRange,
        possibleTypes: FastArenaRange,
        enumValues: FastArenaRange
    ) {
        self.kind = kind
        self.name = name
        self.fields = fields
        self.inputFields = inputFields
        self.interfaces = interfaces
        self.possibleTypes = possibleTypes
        self.enumValues = enumValues
    }
}

@frozen
public struct FastSchemaEnumValue: Sendable {
    public let name: FastSchemaNameID
    public let isDeprecated: Bool

    @inlinable
    public init(name: FastSchemaNameID, isDeprecated: Bool) {
        self.name = name
        self.isDeprecated = isDeprecated
    }
}

@frozen
public struct FastDirectiveLocations: OptionSet, Sendable {
    public let rawValue: UInt32

    @inlinable
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let query = Self(rawValue: 1 << 0)
    public static let mutation = Self(rawValue: 1 << 1)
    public static let subscription = Self(rawValue: 1 << 2)
    public static let field = Self(rawValue: 1 << 3)
    public static let fragmentDefinition = Self(rawValue: 1 << 4)
    public static let fragmentSpread = Self(rawValue: 1 << 5)
    public static let fragmentVariableDefinition = Self(rawValue: 1 << 6)
    public static let inlineFragment = Self(rawValue: 1 << 7)
    public static let variableDefinition = Self(rawValue: 1 << 8)
    public static let schema = Self(rawValue: 1 << 9)
    public static let scalar = Self(rawValue: 1 << 10)
    public static let object = Self(rawValue: 1 << 11)
    public static let fieldDefinition = Self(rawValue: 1 << 12)
    public static let argumentDefinition = Self(rawValue: 1 << 13)
    public static let interface = Self(rawValue: 1 << 14)
    public static let union = Self(rawValue: 1 << 15)
    public static let `enum` = Self(rawValue: 1 << 16)
    public static let enumValue = Self(rawValue: 1 << 17)
    public static let inputObject = Self(rawValue: 1 << 18)
    public static let inputFieldDefinition = Self(rawValue: 1 << 19)
}

@frozen
public struct FastSchemaDirective: Sendable {
    public let name: FastSchemaNameID
    public let arguments: FastArenaRange
    public let locations: FastDirectiveLocations
    public let isRepeatable: Bool

    @inlinable
    public init(
        name: FastSchemaNameID,
        arguments: FastArenaRange,
        locations: FastDirectiveLocations,
        isRepeatable: Bool
    ) {
        self.name = name
        self.arguments = arguments
        self.locations = locations
        self.isRepeatable = isRepeatable
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
public enum FastSchemaFieldResolverKind: UInt8, Sendable {
    case sourceOnly
    case synchronous
    case asynchronous
}

@frozen
public struct FastSchemaField: Sendable {
    public let parentType: FastSchemaTypeID
    public let name: FastSchemaNameID
    public let type: FastSchemaTypeReferenceID
    public let arguments: FastArenaRange
    public let isDeprecated: Bool
    public let resolverKind: FastSchemaFieldResolverKind
    public let resolverIsComplete: Bool
    public let hasCustomSubscribe: Bool

    @inlinable
    public init(
        parentType: FastSchemaTypeID,
        name: FastSchemaNameID,
        type: FastSchemaTypeReferenceID,
        arguments: FastArenaRange,
        isDeprecated: Bool,
        resolverKind: FastSchemaFieldResolverKind,
        resolverIsComplete: Bool,
        hasCustomSubscribe: Bool
    ) {
        self.parentType = parentType
        self.name = name
        self.type = type
        self.arguments = arguments
        self.isDeprecated = isDeprecated
        self.resolverKind = resolverKind
        self.resolverIsComplete = resolverIsComplete
        self.hasCustomSubscribe = hasCustomSubscribe
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
public final class FastCompiledSchema: Sendable {
    public let names: ContiguousArray<String>
    public let types: ContiguousArray<FastSchemaType>
    public let typeReferences: ContiguousArray<FastSchemaTypeReference>
    public let fields: ContiguousArray<FastSchemaField>
    public let inputValues: ContiguousArray<FastSchemaInputValue>
    public let typeMembers: ContiguousArray<FastSchemaTypeID>
    public let enumValues: ContiguousArray<FastSchemaEnumValue>
    public let directives: ContiguousArray<FastSchemaDirective>
    public let roots: FastSchemaRoots

    @usableFromInline let nameLookup: [String: FastSchemaNameID]
    @usableFromInline let typeLookup: [String: FastSchemaTypeID]
    @usableFromInline let fieldLookup: [FieldLookupKey: FastSchemaFieldID]
    @usableFromInline let directiveLookup: [FastSchemaNameID: FastSchemaDirectiveID]

    public init(
        names: ContiguousArray<String>,
        types: ContiguousArray<FastSchemaType>,
        typeReferences: ContiguousArray<FastSchemaTypeReference>,
        fields: ContiguousArray<FastSchemaField>,
        inputValues: ContiguousArray<FastSchemaInputValue>,
        typeMembers: ContiguousArray<FastSchemaTypeID>,
        enumValues: ContiguousArray<FastSchemaEnumValue>,
        directives: ContiguousArray<FastSchemaDirective>,
        roots: FastSchemaRoots
    ) {
        self.names = names
        self.types = types
        self.typeReferences = typeReferences
        self.fields = fields
        self.inputValues = inputValues
        self.typeMembers = typeMembers
        self.enumValues = enumValues
        self.directives = directives
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

        var directivesByName: [FastSchemaNameID: FastSchemaDirectiveID] = [:]
        directivesByName.reserveCapacity(directives.count)
        for (index, directive) in directives.enumerated() {
            directivesByName[directive.name] = FastSchemaDirectiveID(rawValue: UInt32(index))
        }
        directiveLookup = directivesByName
    }

    @inlinable
    public func name(_ id: FastSchemaNameID) -> String {
        names[Int(id.rawValue)]
    }

    @inlinable
    public func typeID(named name: String) -> FastSchemaTypeID? {
        typeLookup[name]
    }

    @inlinable
    public func fieldID(
        on parent: FastSchemaTypeID,
        named name: String
    ) -> FastSchemaFieldID? {
        guard let name = nameLookup[name] else { return nil }
        return fieldLookup[FieldLookupKey(parent: parent, name: name)]
    }

    @inlinable
    public func directiveID(named name: String) -> FastSchemaDirectiveID? {
        guard let name = nameLookup[name] else { return nil }
        return directiveLookup[name]
    }

    @inlinable
    public func isPossibleType(
        _ possibleType: FastSchemaTypeID,
        for abstractType: FastSchemaTypeID
    ) -> Bool {
        let range = types[Int(abstractType.rawValue)].possibleTypes
        let end = range.start + range.count
        for index in range.start ..< end where typeMembers[Int(index)] == possibleType {
            return true
        }
        return false
    }
}

@usableFromInline
struct FieldLookupKey: Sendable, Hashable {
    let parent: FastSchemaTypeID
    let name: FastSchemaNameID

    @usableFromInline
    init(parent: FastSchemaTypeID, name: FastSchemaNameID) {
        self.parent = parent
        self.name = name
    }
}
