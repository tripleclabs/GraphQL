/// Restores a Sendable marker conformance after a dynamic API has erased static type information.
///
/// Swift does not support conditional casts to marker protocols. Callers must establish the
/// Sendable invariant before type erasure and use this only at that erasure boundary.
@inline(__always)
func assumeSendable(_ value: Any) -> any Sendable {
    restoringErasedMarkerConformance(value, to: (any Sendable).self)
}

/// Restores the Sendable marker carried by a resolver result after casting it to AsyncSequence.
@inline(__always)
func restoringSendableConformance(
    of sequence: any AsyncSequence
) -> any AsyncSequence & Sendable {
    restoringErasedMarkerConformance(sequence, to: (any AsyncSequence & Sendable).self)
}

/// Performs the runtime cast needed to rebuild an existential after a dynamic API erases a marker
/// protocol. Keeping the source and destination generic avoids Swift's contradictory diagnostics
/// for concrete casts to marker protocols while retaining the cast's runtime representation work.
@inline(__always)
private func restoringErasedMarkerConformance<Value, Result>(
    _ value: Value,
    to _: Result.Type
) -> Result {
    value as! Result
}
