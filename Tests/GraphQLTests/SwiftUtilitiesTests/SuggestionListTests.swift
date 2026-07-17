@testable import GraphQL
import Testing

@Suite struct SuggestionListTests {
    @Test func lexicalDistanceCountsEditsAndTranspositions() {
        #expect(lexicalDistance("", "") == 0)
        #expect(lexicalDistance("abc", "abc") == 0)
        #expect(lexicalDistance("abc", "axc") == 1)
        #expect(lexicalDistance("abc", "ab") == 1)
        #expect(lexicalDistance("ab", "abc") == 1)
        #expect(lexicalDistance("ab", "ba") == 1)
        #expect(lexicalDistance("kitten", "sitting") == 3)
    }

    @Test func lexicalDistanceHonorsMaximumDistance() {
        #expect(lexicalDistance("MassiveType199X", "MassiveType1999", maximumDistance: 1) == 1)
        #expect(lexicalDistance("short", "muchLonger", maximumDistance: 2) == 3)
        #expect(lexicalDistance("kitten", "sitting", maximumDistance: 2) == 3)
    }

    @Test func boundedDistanceMatchesExactDistanceExhaustively() {
        let strings = allStrings(alphabet: ["a", "b", "c"], maximumLength: 4)

        for left in strings {
            for right in strings {
                let exact = lexicalDistance(left, right)
                for limit in 0 ... 4 {
                    #expect(
                        lexicalDistance(left, right, maximumDistance: limit)
                            == min(exact, limit + 1)
                    )
                }
            }
        }
    }

    @Test func suggestionsPreserveDistanceThenLexicalOrdering() {
        #expect(
            suggestionList(
                input: "MassiveType199X",
                options: ["Unrelated", "MassiveType1998", "MassiveType1999", "MassiveType0199"]
            ) == ["MassiveType1998", "MassiveType1999", "MassiveType0199"]
        )
    }

    @Test func suggestionsRetainOnlyTheDisplayableResults() {
        #expect(
            suggestionList(
                input: "TypeX",
                options: ["Type6", "Type5", "Type4", "Type3", "Type2", "Type1"]
            ) == ["Type1", "Type2", "Type3", "Type4", "Type5"]
        )
    }
}

private func allStrings(alphabet: [String], maximumLength: Int) -> [String] {
    var result = [""]
    var previousLength = [""]

    for _ in 1 ... maximumLength {
        let currentLength = previousLength.flatMap { prefix in
            alphabet.map { prefix + $0 }
        }
        result.append(contentsOf: currentLength)
        previousLength = currentLength
    }

    return result
}
