/**
 * Given an invalid input string and a list of valid options, returns a filtered
 * list of valid options sorted based on their similarity with the input. Only
 * the options that can be displayed by `didYouMean` are retained.
 */
func suggestionList(
    input: String,
    options: [String]
) -> [String] {
    var optionsByDistance: [(option: String, distance: Int)] = []
    optionsByDistance.reserveCapacity(min(options.count, maximumSuggestionCount))
    let inputThreshold = input.utf8.count / 2
    var lexicalDistance = LexicalDistance(input)

    for option in options {
        let threshold = max(inputThreshold, option.utf8.count / 2, 1)
        let distance = lexicalDistance.measure(option, maximumDistance: threshold)

        if distance <= threshold {
            let candidate = (option: option, distance: distance)
            let insertionIndex = optionsByDistance.firstIndex {
                candidate.distance < $0.distance ||
                    candidate.distance == $0.distance &&
                    candidate.option.lexicographicallyPrecedes($0.option)
            }

            if let insertionIndex {
                optionsByDistance.insert(candidate, at: insertionIndex)
            } else if optionsByDistance.count < maximumSuggestionCount {
                optionsByDistance.append(candidate)
            }

            if optionsByDistance.count > maximumSuggestionCount {
                optionsByDistance.removeLast()
            }
        }
    }
    return optionsByDistance.map(\.option)
}

/**
 * Computes the lexical distance between strings A and B.
 *
 * The "distance" between two strings is given by counting the minimum number
 * of edits needed to transform string A into string B. An edit can be an
 * insertion, deletion, or substitution of a single character, or a swap of two
 * adjacent characters.
 *
 * This distance can be useful for detecting typos in input or sorting
 *
 */
func lexicalDistance(
    _ a: String,
    _ b: String,
    maximumDistance: Int? = nil
) -> Int {
    var lexicalDistance = LexicalDistance(a)
    return lexicalDistance.measure(b, maximumDistance: maximumDistance)
}

private struct LexicalDistance {
    let input: [UInt8]
    var twoRowsBack: [Int] = []
    var previousRow: [Int] = []
    var currentRow: [Int] = []

    init(_ input: String) {
        self.input = Array(input.utf8)
    }

    mutating func measure(_ option: String, maximumDistance: Int? = nil) -> Int {
        let bBytes = Array(option.utf8)
        let aLength = input.count
        let bLength = bBytes.count
        let limit = maximumDistance ?? max(aLength, bLength)

        precondition(limit >= 0, "maximumDistance must not be negative")

        if abs(aLength - bLength) > limit {
            return limit + 1
        }
        if aLength == 0 {
            return bLength
        }
        if bLength == 0 {
            return aLength
        }

        if previousRow.count < bLength + 1 {
            twoRowsBack = [Int](repeating: 0, count: bLength + 1)
            previousRow = [Int](repeating: 0, count: bLength + 1)
            currentRow = [Int](repeating: 0, count: bLength + 1)
        }
        for index in 0 ... bLength {
            previousRow[index] = index
        }

        for i in 1 ... aLength {
            currentRow[0] = i <= limit ? i : limit + 1
            let lowerBound = max(1, i - limit)
            let upperBound = min(bLength, i + limit)

            if lowerBound > 1 {
                currentRow[lowerBound - 1] = limit + 1
            }

            for j in lowerBound ... upperBound {
                let cost = input[i - 1] == bBytes[j - 1] ? 0 : 1
                currentRow[j] = min(
                    currentRow[j - 1] + 1,
                    previousRow[j] + 1,
                    previousRow[j - 1] + cost
                )

                if
                    i > 1, j > 1,
                    input[i - 1] == bBytes[j - 2],
                    input[i - 2] == bBytes[j - 1]
                {
                    currentRow[j] = min(currentRow[j], twoRowsBack[j - 2] + cost)
                }
            }

            if upperBound < bLength {
                currentRow[upperBound + 1] = limit + 1
            }

            swap(&twoRowsBack, &previousRow)
            swap(&previousRow, &currentRow)
        }

        let distance = previousRow[bLength]
        if distance > limit {
            return limit + 1
        }
        return distance
    }
}
