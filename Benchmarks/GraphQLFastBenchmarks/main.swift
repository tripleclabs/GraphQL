import Foundation
@_spi(EngineV2Benchmark) import GraphQL
import GraphQLFast

private let successfulQuery = """
query SingleItem {
  person(id: "1") {
    id
    name
    birthYear
    species { id name classification }
  }
}
"""

private let malformedQuery = """
query Malformed {
  person(id: "1") {
    id
    name
"""

private let environment = ProcessInfo.processInfo.environment
private let warmup = Int(environment["WARMUP"] ?? "1000") ?? 1000
private let iterations = Int(environment["ITERATIONS"] ?? "10000") ?? 10000
private let sampleCount = Int(environment["SAMPLES"] ?? "15") ?? 15

private struct Measurement {
    let name: String
    let samples: [Double]
    let checksum: Int

    var median: Double {
        samples.sorted()[samples.count / 2]
    }
}

@inline(never)
private func consumeError(_ error: any Error) -> Int {
    // The concrete error remains live across this call, preventing the throwing path from being
    // optimized away without eagerly formatting its public description.
    withExtendedLifetime(error) { 1 }
}

@inline(never)
private func consumeTokens(_ tokens: ContiguousArray<FastToken>) -> Int {
    var checksum = 0
    for token in tokens {
        checksum &+= Int(token.range.start) &* 31 &+ Int(token.range.end)
    }
    return checksum
}

@inline(never)
private func consumeReferenceDocument(_ document: Document) -> Int {
    withExtendedLifetime(document) { document.definitions.count }
}

@inline(never)
private func consumeFastDocument(_ document: FastDocument) -> Int {
    var checksum = document.operations.count &+ document.selections.count
    for operation in document.operations {
        checksum &+= Int(operation.selectionSet)
        checksum &+= Int(operation.name?.start ?? 0)
    }
    for selection in document.selections {
        checksum &+= Int(selection.name?.start ?? 0)
        checksum &+= Int(selection.name?.end ?? 0)
        checksum &+= Int(selection.selectionSet ?? 0)
        checksum &+= Int(selection.nextSibling ?? 0)
    }
    for argument in document.arguments {
        checksum &+= Int(argument.name.start) &+ Int(argument.value)
    }
    for value in document.values {
        checksum &+= Int(value.source.start) &+ Int(value.source.end)
    }
    return checksum
}

private func measure(
    _ name: String,
    operation: () throws -> Int
) -> Measurement {
    var checksum = 0
    for _ in 0 ..< warmup {
        checksum &+= (try? operation()) ?? 1
    }

    var samples: [Double] = []
    samples.reserveCapacity(sampleCount)
    for _ in 0 ..< sampleCount {
        let start = DispatchTime.now().uptimeNanoseconds
        for _ in 0 ..< iterations {
            checksum &+= (try? operation()) ?? 1
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        samples.append(Double(elapsed) / Double(iterations))
    }
    return Measurement(name: name, samples: samples, checksum: checksum)
}

private let measurements = [
    measure("v1_lex_success") {
        try engineV1TokenChecksum(successfulQuery)
    },
    measure("v2_lex_success") {
        try consumeTokens(FastLexer.tokenize(successfulQuery))
    },
    measure("v1_parse_success") {
        try consumeReferenceDocument(parse(source: successfulQuery, noLocation: true))
    },
    measure("v2_parse_success") {
        try consumeFastDocument(FastParser.parse(successfulQuery))
    },
    measure("v1_parse_malformed") {
        do {
            return try parse(source: malformedQuery, noLocation: true).definitions.count
        } catch {
            return consumeError(error)
        }
    },
    measure("v2_parse_malformed") {
        do {
            return try FastParser.parse(malformedQuery).operations.count
        } catch {
            return consumeError(error)
        }
    },
]

print("Release microbenchmark: \(warmup) warmups, \(iterations) iterations, \(sampleCount) samples")
print("| Boundary | Median |")
print("| --- | ---: |")
for measurement in measurements {
    print("| \(measurement.name) | \(String(format: "%.2f ns", measurement.median)) |")
}
print("checksum=\(measurements.reduce(0) { $0 &+ $1.checksum })")
