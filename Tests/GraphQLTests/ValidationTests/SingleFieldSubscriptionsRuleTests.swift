@testable import GraphQL
import Testing

/// https://spec.graphql.org/draft/#sec-Single-root-field
private let subscriptionSchema: GraphQLSchema = {
    let message = try! GraphQLObjectType(
        name: "Message",
        fields: ["body": GraphQLField(type: GraphQLString)]
    )
    let query = try! GraphQLObjectType(
        name: "Query",
        fields: ["placeholder": GraphQLField(type: GraphQLString)]
    )
    let subscription = try! GraphQLObjectType(
        name: "Subscription",
        fields: [
            "newMessage": GraphQLField(type: message),
            "newNotification": GraphQLField(type: message),
        ]
    )
    return try! GraphQLSchema(query: query, subscription: subscription)
}()

class SingleFieldSubscriptionsRuleTests: ValidationTestCase {
    override init() {
        super.init()
        rule = SingleFieldSubscriptionsRule
    }

    // MARK: Valid

    @Test func singleRootField() throws {
        try assertValid(
            """
            subscription Sub { newMessage { body } }
            """,
            schema: subscriptionSchema
        )
    }

    @Test func anonymousSingleRootField() throws {
        try assertValid(
            """
            subscription { newMessage { body } }
            """,
            schema: subscriptionSchema
        )
    }

    @Test func singleRootFieldViaFragment() throws {
        try assertValid(
            """
            subscription Sub { ...newMessageFields }
            fragment newMessageFields on Subscription { newMessage { body } }
            """,
            schema: subscriptionSchema
        )
    }

    @Test func queriesMayHaveManyRootFields() throws {
        try assertValid(
            """
            query Q { placeholder anotherPlaceholder }
            """,
            schema: subscriptionSchema
        )
    }

    // MARK: Invalid — field count

    @Test func twoRootFieldsAreRejected() throws {
        let errors = try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { newMessage { body } newNotification { body } }
            """,
            schema: subscriptionSchema
        )
        #expect(errors.first?.message == "Subscription \"Sub\" must select only one field.")
    }

    @Test func anonymousSubscriptionReportsWithoutAName() throws {
        let errors = try assertInvalid(
            errorCount: 1,
            query: """
            subscription { newMessage { body } newNotification { body } }
            """,
            schema: subscriptionSchema
        )
        #expect(errors.first?.message == "Anonymous Subscription must select only one field.")
    }

    /// Collection happens after fragments are expanded, so a fragment cannot be
    /// used to smuggle in a second root field.
    @Test func fragmentCannotSmuggleInASecondRootField() throws {
        try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { newMessage { body } ...more }
            fragment more on Subscription { newNotification { body } }
            """,
            schema: subscriptionSchema
        )
    }

    @Test func twoFieldsInsideOneFragmentAreRejected() throws {
        try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { ...both }
            fragment both on Subscription { newMessage { body } newNotification { body } }
            """,
            schema: subscriptionSchema
        )
    }

    // MARK: Invalid — introspection root

    @Test func introspectionFieldAsRootIsRejected() throws {
        let errors = try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { __typename }
            """,
            schema: subscriptionSchema
        )
        #expect(
            errors.first?.message ==
                "Subscription \"Sub\" must not select an introspection top level field."
        )
    }

    @Test func anonymousIntrospectionRootIsRejected() throws {
        let errors = try assertInvalid(
            errorCount: 1,
            query: """
            subscription { __typename }
            """,
            schema: subscriptionSchema
        )
        #expect(
            errors.first?.message ==
                "Anonymous Subscription must not select an introspection top level field."
        )
    }

    // MARK: Invalid — @skip / @include in the root selection set

    /// CollectSubscriptionFields has no access to variable values, so whether an
    /// operation is valid must not depend on them. The spec forbids these
    /// directives outright rather than evaluating them.
    @Test func skipOnRootSelectionIsRejected() throws {
        let errors = try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { newMessage @skip(if: true) { body } }
            """,
            schema: subscriptionSchema
        )
        #expect(
            errors.first?.message ==
                "Subscription \"Sub\" must not provide the @skip or @include directive on its root selection set."
        )
    }

    @Test func includeOnRootSelectionIsRejected() throws {
        try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { newMessage @include(if: false) { body } }
            """,
            schema: subscriptionSchema
        )
    }

    @Test func skipOnARootFragmentSpreadIsRejected() throws {
        try assertInvalid(
            errorCount: 1,
            query: """
            subscription Sub { ...fields @skip(if: true) }
            fragment fields on Subscription { newMessage { body } }
            """,
            schema: subscriptionSchema
        )
    }

    /// Only the *root* selection set is restricted; nested selections are normal.
    @Test func skipDeeperInTheQueryIsAllowed() throws {
        try assertValid(
            """
            subscription Sub { newMessage { body @skip(if: true) } }
            """,
            schema: subscriptionSchema
        )
    }
}
