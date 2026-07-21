/// Exposes the Engine V1 lexer boundary to the local Engine V2 benchmark executable without
/// making lexer implementation types part of the supported GraphQL API.
@_spi(EngineV2Benchmark)
public func engineV1TokenChecksum(_ source: String) throws -> Int {
    let lexer = createLexer(source: Source(body: source), noLocation: true)
    var checksum = 0
    while true {
        let token = try lexer.advance()
        checksum &+= token.start &* 31 &+ token.end
        if token.kind == .eof { return checksum }
    }
}
