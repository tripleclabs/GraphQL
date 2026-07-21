/// A byte range into the original UTF-8 GraphQL source.
///
/// Engine V2 keeps names and literal spellings as offsets rather than allocating a `String` for
/// each occurrence. The source string owns the referenced bytes for the document lifetime.
@frozen
public struct FastSourceRange: Sendable, Hashable {
    public let start: UInt32
    public let end: UInt32

    @inlinable
    public init(start: UInt32, end: UInt32) {
        self.start = start
        self.end = end
    }
}

/// A contiguous range within one of the document's node arenas.
@frozen
public struct FastArenaRange: Sendable, Hashable {
    public let start: UInt32
    public let count: UInt32

    @inlinable
    public init(start: UInt32, count: UInt32) {
        self.start = start
        self.count = count
    }

    public static let empty = FastArenaRange(start: 0, count: 0)
}

/// The compact executable-document representation populated by the Engine V2 parser.
///
/// Nodes live in typed contiguous arenas and refer to one another by integer ranges. Keeping the
/// source here makes every name and literal slice valid without per-node string allocation.
public struct FastDocument: Sendable {
    public let source: String
    public internal(set) var operations: ContiguousArray<FastOperation>
    public internal(set) var fragments: ContiguousArray<FastFragment>
    public internal(set) var variableDefinitions: ContiguousArray<FastVariableDefinition>
    public internal(set) var types: ContiguousArray<FastTypeReference>
    public internal(set) var directives: ContiguousArray<FastDirective>
    public internal(set) var selectionSets: ContiguousArray<FastSelectionSet>
    public internal(set) var selections: ContiguousArray<FastSelection>
    public internal(set) var arguments: ContiguousArray<FastArgument>
    public internal(set) var values: ContiguousArray<FastValue>
    public internal(set) var objectFields: ContiguousArray<FastObjectField>

    public init(source: String) {
        self.source = source
        operations = []
        fragments = []
        variableDefinitions = []
        types = []
        directives = []
        selectionSets = []
        selections = []
        arguments = []
        values = []
        objectFields = []
    }
}

@frozen
public struct FastOperation: Sendable {
    public enum Kind: UInt8, Sendable {
        case query
        case mutation
        case subscription
    }

    public let kind: Kind
    public let name: FastSourceRange?
    public let variableDefinitions: FastArenaRange
    public let directives: FastArenaRange
    public let selectionSet: UInt32
}

@frozen
public struct FastFragment: Sendable {
    public let name: FastSourceRange
    public let typeCondition: FastSourceRange
    public let directives: FastArenaRange
    public let selectionSet: UInt32
}

@frozen
public struct FastVariableDefinition: Sendable {
    public let name: FastSourceRange
    public let type: UInt32
    public let defaultValue: UInt32?
    public let directives: FastArenaRange
}

@frozen
public struct FastTypeReference: Sendable {
    public enum Kind: UInt8, Sendable {
        case named
        case list
        case nonNull
    }

    public let kind: Kind
    public let name: FastSourceRange?
    public let wrappedType: UInt32?
}

@frozen
public struct FastDirective: Sendable {
    public let name: FastSourceRange
    public let arguments: FastArenaRange
}

@frozen
public struct FastSelectionSet: Sendable {
    public internal(set) var firstSelection: UInt32?
    public internal(set) var selectionCount: UInt32
}

@frozen
public struct FastSelection: Sendable {
    public enum Kind: UInt8, Sendable {
        case field
        case fragmentSpread
        case inlineFragment
    }

    public let kind: Kind
    public let name: FastSourceRange?
    public let alias: FastSourceRange?
    public let arguments: FastArenaRange
    public let directives: FastArenaRange
    public let selectionSet: UInt32?
    public let typeCondition: FastSourceRange?
    public internal(set) var nextSibling: UInt32?
}

@frozen
public struct FastArgument: Sendable {
    public let name: FastSourceRange
    public let value: UInt32
}

@frozen
public struct FastValue: Sendable {
    public enum Kind: UInt8, Sendable {
        case variable
        case integer
        case float
        case string
        case boolean
        case null
        case `enum`
        case list
        case object
    }

    public let kind: Kind
    public let source: FastSourceRange
    public let firstChild: UInt32?
    public let childCount: UInt32
    public internal(set) var nextSibling: UInt32?
}

@frozen
public struct FastObjectField: Sendable {
    public let name: FastSourceRange
    public let value: UInt32
    public internal(set) var nextSibling: UInt32?
}
