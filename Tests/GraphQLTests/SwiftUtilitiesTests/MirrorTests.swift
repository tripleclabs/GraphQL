@testable import GraphQL
import Testing

@Suite struct MirrorTests {
    @Test func unwrapsSendableOptionals() {
        let present: String? = "value"
        let missing: String? = nil

        #expect(unwrap(present) as? String == "value")
        #expect(unwrap(missing) == nil)
        #expect(unwrap("value") as? String == "value")
    }

    @Test func readsAndUnwrapsReflectedSendableProperties() {
        struct Source: Sendable {
            let present: String? = "value"
            let missing: String? = nil
        }

        let mirror = Mirror(reflecting: Source())
        #expect(mirror.getValue(named: "present") as? String == "value")
        #expect(mirror.getValue(named: "missing") == nil)
        #expect(mirror.getValue(named: "unknown") == nil)
    }
}
