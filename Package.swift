// swift-tools-version:5.8
import PackageDescription

let package = Package(
    name: "GraphQL",
    platforms: [.macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6)],
    products: [
        .library(name: "GraphQL", targets: ["GraphQL"]),
        .executable(name: "graphql-fast-benchmarks", targets: ["GraphQLFastBenchmarks"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-collections", .upToNextMajor(from: "1.0.0")),
    ],
    targets: [
        .target(name: "GraphQLFast"),
        .target(
            name: "GraphQL",
            dependencies: [
                "GraphQLFast",
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .testTarget(
            name: "GraphQLFastTests",
            dependencies: ["GraphQLFast", "GraphQL"]
        ),
        .executableTarget(
            name: "GraphQLFastBenchmarks",
            dependencies: ["GraphQLFast", "GraphQL"],
            path: "Benchmarks/GraphQLFastBenchmarks"
        ),
        .testTarget(
            name: "GraphQLTests",
            dependencies: ["GraphQL"],
            resources: [
                .copy("LanguageTests/kitchen-sink.graphql"),
                .copy("LanguageTests/schema-kitchen-sink.graphql"),
            ]
        ),
    ],
    swiftLanguageVersions: [.v5, .version("6")]
)
