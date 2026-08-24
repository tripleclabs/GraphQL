@testable import GraphQL
import Testing

@Suite struct IntrospectionTests {
    @Test func defaultValues() async throws {
        let numEnum = try GraphQLEnumType(
            name: "Enum",
            values: [
                "One": .init(value: "One"),
                "Two": .init(value: "Two"),
            ]
        )
        let inputObject = try GraphQLInputObjectType(
            name: "InputObject",
            fields: ["str": .init(type: GraphQLString)]
        )
        let outputObject = try GraphQLObjectType(
            name: "Object",
            fields: ["str": .init(type: GraphQLString)]
        )

        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "bool": .init(
                    type: GraphQLBoolean,
                    args: [
                        "bool": .init(
                            type: GraphQLBoolean,
                            defaultValue: true
                        ),
                    ]
                ),
                "enum": .init(
                    type: numEnum,
                    args: [
                        "enum": .init(
                            type: numEnum,
                            defaultValue: "One"
                        ),
                    ]
                ),
                "float": .init(
                    type: GraphQLFloat,
                    args: [
                        "float": .init(
                            type: GraphQLFloat,
                            defaultValue: 2.2
                        ),
                    ]
                ),
                "id": .init(
                    type: GraphQLID,
                    args: [
                        "id": .init(
                            type: GraphQLID,
                            defaultValue: "5"
                        ),
                    ]
                ),
                "int": .init(
                    type: GraphQLInt,
                    args: [
                        "int": .init(
                            type: GraphQLInt,
                            defaultValue: 5
                        ),
                    ]
                ),
                "list": .init(
                    type: GraphQLList(GraphQLInt),
                    args: [
                        "list": .init(
                            type: GraphQLList(GraphQLInt),
                            defaultValue: [1, 2, 3]
                        ),
                    ]
                ),
                "object": .init(
                    type: outputObject,
                    args: [
                        "input": .init(
                            type: inputObject,
                            defaultValue: ["str": "hello"]
                        ),
                    ]
                ),
                "string": .init(
                    type: GraphQLString,
                    args: [
                        "string": .init(
                            type: GraphQLString,
                            defaultValue: "hello"
                        ),
                    ]
                ),
            ]
        )

        let schema = try GraphQLSchema(query: query, types: [inputObject, outputObject])

        let introspection = try await graphql(
            schema: schema,
            request: """
            query IntrospectionTypeQuery {
              __schema {
                types {
                  fields {
                    args {
                      defaultValue
                      name
                      type {
                        name
                      }
                    }
                    name
                    type {
                      name
                    }
                  }
                  name
                }
              }
            }
            """
        )

        let queryType = try #require(
            introspection.data?["__schema"]["types"].array?
                .find { $0["name"] == "Query" }
        )

        #expect(
            queryType == [
                "fields": [
                    [
                        "args": [
                            [
                                "defaultValue": "true",
                                "name": "bool",
                                "type": [
                                    "name": "Boolean",
                                ],
                            ],
                        ],
                        "name": "bool",
                        "type": [
                            "name": "Boolean",
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "One",
                                "name": "enum",
                                "type": [
                                    "name": "Enum",
                                ],
                            ],
                        ],
                        "name": "enum",
                        "type": [
                            "name": "Enum",
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "2.2",
                                "name": "float",
                                "type": [
                                    "name": "Float",
                                ],
                            ],
                        ],
                        "name": "float",
                        "type": [
                            "name": "Float",
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "5",
                                "name": "id",
                                "type": [
                                    "name": "ID",
                                ],
                            ],
                        ],
                        "name": "id",
                        "type": [
                            "name": "ID",
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "5",
                                "name": "int",
                                "type": [
                                    "name": "Int",
                                ],
                            ],
                        ],
                        "name": "int",
                        "type": [
                            "name": "Int",
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "[1, 2, 3]",
                                "name": "list",
                                "type": [
                                    "name": .null,
                                ],
                            ],
                        ],
                        "name": "list",
                        "type": [
                            "name": .null,
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "{ str: \"hello\" }",
                                "name": "input",
                                "type": [
                                    "name": "InputObject",
                                ],
                            ],
                        ],
                        "name": "object",
                        "type": [
                            "name": "Object",
                        ],
                    ],
                    [
                        "args": [
                            [
                                "defaultValue": "\"hello\"",
                                "name": "string",
                                "type": [
                                    "name": "String",
                                ],
                            ],
                        ],
                        "name": "string",
                        "type": [
                            "name": "String",
                        ],
                    ],
                ],
                "name": "Query",
            ]
        )
    }
}

/// `__InputValue.defaultValue` is produced by `astFromValue`, so it shares the
/// string encoding used when printing SDL. The `defaultValues` fixture above
/// only covers `"hello"`, which is identical under any encoding; these pin the
/// characters that actually distinguish one encoding from another.
@Suite struct IntrospectionDefaultValueEncodingTests {
    private func introspectDefault(_ defaultValue: Map) async throws -> String? {
        let query = try GraphQLObjectType(
            name: "Query",
            fields: [
                "f": GraphQLField(
                    type: GraphQLString,
                    args: [
                        "a": GraphQLArgument(type: GraphQLString, defaultValue: defaultValue),
                    ]
                ),
            ]
        )
        let schema = try GraphQLSchema(query: query)
        let result = try await graphql(
            schema: schema,
            request: """
            query {
              __type(name: "Query") {
                fields { args { defaultValue } }
              }
            }
            """
        )
        return result.data?["__type"]["fields"][0]["args"][0]["defaultValue"].string
    }

    @Test func slashesAreNotEscaped() async throws {
        // The old JSON round-trip produced "http:\\/\\/x.com\\/y", and \/ is not
        // a valid escape in a GraphQL string literal, so clients could not parse it.
        #expect(try await introspectDefault("http://x.com/y") == "\"http://x.com/y\"")
    }

    @Test func quotesAndBackslashesAreStillEscaped() async throws {
        #expect(try await introspectDefault("a\"b\\c") == "\"a\\\"b\\\\c\"")
    }

    @Test func controlCharactersAreStillEscaped() async throws {
        #expect(try await introspectDefault("a\nb") == "\"a\\nb\"")
    }
}
