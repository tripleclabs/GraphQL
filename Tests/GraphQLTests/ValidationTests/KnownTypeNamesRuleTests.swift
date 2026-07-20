@testable import GraphQL
import Testing

class KnownTypeNamesRuleTests: ValidationTestCase {
    override init() {
        super.init()
        rule = KnownTypeNamesRule
    }

    @Test func knownTypeNamesAreValid() throws {
        try assertValid(
            """
            query Foo(
              $var: String
              $required: [Int!]!
              $introspectionType: __EnumValue
            ) {
              user(id: 4) {
                pets { ... on Pet { name }, ...PetFields, ... { name } }
              }
            }

            fragment PetFields on Pet {
              name
            }
            """
        )
    }

    @Test func unknownTypeNamesAreInvalid() throws {
        let errors = try assertInvalid(
            errorCount: 3,
            query:
            """
            query Foo($var: [JumbledUpLetters!]!) {
              user(id: 4) {
                name
                pets { ... on Badger { name }, ...PetFields }
              }
            }
            fragment PetFields on Peat {
              name
            }
            """
        )
        try assertValidationError(
            error: errors[0],
            locations: [(line: 1, column: 18)],
            message: "Unknown type \"JumbledUpLetters\"."
        )
        try assertValidationError(
            error: errors[1],
            locations: [(line: 4, column: 19)],
            message: "Unknown type \"Badger\"."
        )
        try assertValidationError(
            error: errors[2],
            locations: [(line: 7, column: 23)],
            message: "Unknown type \"Peat\". Did you mean \"Pet\" or \"Cat\"?"
        )
    }
}

class KnownTypeNamesSDLRuleTests: SDLValidationTestCase {
    override init() {
        super.init()
        rule = KnownTypeNamesRule
    }

    @Test func recognizesTypesDefinedInTheDocument() throws {
        try assertValidationErrors(
            """
            type Query { local: Local }
            type Local { value: String }
            """,
            []
        )
    }

    @Test func suggestsTypesDefinedInTheDocument() throws {
        try assertValidationErrors(
            """
            type Query { local: Locla }
            type Local { value: String }
            """,
            [
                GraphQLError(
                    message: #"Unknown type "Locla". Did you mean "Local"?"#,
                    locations: [.init(line: 1, column: 21)]
                ),
            ]
        )
    }
}
