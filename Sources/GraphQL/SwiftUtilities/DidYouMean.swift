let maximumSuggestionCount = 5

func didYouMean(_ submessage: String? = nil, suggestions: [String]) -> String {
    guard !suggestions.isEmpty else {
        return ""
    }

    var message = " Did you mean "
    if let submessage = submessage {
        message.append("\(submessage) ")
    }

    let suggestionList = suggestions[0 ... min(suggestions.count - 1, maximumSuggestionCount - 1)]
        .map { "\"\($0)\"" }.orList()
    return message + "\(suggestionList)?"
}
