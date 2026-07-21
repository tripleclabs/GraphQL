# GraphQL Engine V2 Plan

## Objective

Build a new `GraphQLFast` engine alongside the existing implementation while retaining:

- The current `GraphQL` public API.
- Existing schema definitions and Graphiti integration.
- The existing execution engine as the reference implementation and fallback.
- The existing GraphQL and Graphiti test suites as the correctness contract.
- Support for both synchronous and asynchronous resolvers.

The first performance objective is to match Rust in the in-process GraphQL benchmark. Initially,
"match" means a median within 10% of Rust for each case on the same machine, with a stretch target
of a comparable six-case geometric mean.

Performance improvements must not come from omitting validation, result materialization, error
construction required by the API, or other work performed by the benchmark contract.

## Project Status

Last updated: 2026-07-21

- [x] Agree the Engine V2 architecture and write this durable plan.
- [ ] Phase 0: Baseline and contracts.
- [x] Phase 1: Compact executable-document parser.
- [ ] Phase 2: Compiled schema representation.
- [ ] Phase 3: Fused validation and plan compilation.
- [ ] Phase 4: Typed resolver dispatch.
- [ ] Phase 5: Arena-backed result construction.
- [ ] Phase 6: Compiled introspection.
- [ ] Phase 7: Controlled cutover.
- [ ] Match Rust within the agreed benchmark tolerance.

### Current milestone

Phase 2 compiled schema representation:

- [x] Define numeric type, field, name, and type-reference IDs.
- [x] Compile all six named type kinds into dense immutable tables.
- [x] Compile object and interface fields.
- [x] Compile arguments, input-object fields, default-presence flags, and aligned default storage.
- [x] Precompute nested named, list, and non-null type-reference shapes.
- [x] Cache one immutable compiled view on the authoritative `GraphQLSchema`.
- [x] Add schema compilation, cache acquisition, type lookup, and field lookup microbenchmarks.
- [x] Compile interface and union membership tables.
- [x] Compile enum values and directive structure, arguments, locations, and repeatability.
- [ ] Compile remaining descriptions, deprecation details, and introspection metadata.
- [ ] Store resolver thunks directly alongside field records.
- [ ] Compile every existing test schema or explicitly classify unsupported behavior.

Status notes and benchmark evidence must be added to this document as work lands. A checked item
means its implementation and proportionate verification are complete, not merely started.

### Microbenchmark policy

Every performance-sensitive subsystem must gain a release-mode microbenchmark when it is
introduced. Each benchmark must:

- Compare Engine V1 and Engine V2 at the same semantic boundary.
- Include successful and failure paths where both exist.
- Perform enough operations per sample to amortize clock overhead.
- Consume results so the optimizer cannot remove the work.
- Report multiple samples and a median rather than a single timing.
- Remain separate from the end-to-end benchmark, which is the final performance authority.

Initial parser microbenchmarks will cover tokenization, successful parsing, and malformed parsing.
Later phases will add schema compilation, validation/plan compilation, resolver dispatch, result
arena construction, public-result conversion, and complete request benchmarks.

## Architecture

```text
Graphiti / application
          |
          v
 Existing GraphQL public API
          |
          +-- GraphQLFast eligible? -- yes --> New engine
          |                                  - parser
          |                                  - validator/compiler
          |                                  - executor
          |                                  - result arena
          |
          +-- unsupported / fallback -------> Existing engine
```

`GraphQLFast` will be a separate package target with no dependency on the existing `GraphQL`
target. The existing module will depend on it and provide adapters for schemas, resolvers, errors,
and results. This avoids a circular dependency and permits an eventual transparent cutover.

The new target will not initially be exposed as a separate package product. It is an implementation
component behind the existing API.

The dependency direction will be:

```text
GraphQLFast <- GraphQL <- Graphiti
```

The existing engine remains operational throughout development. Engine V2 earns traffic through
correctness coverage and measured performance rather than replacing Engine V1 in one large change.

## Baseline

The first optimized Engine V1 release baseline is:

| Case | Swift | Rust | Swift / Rust |
| --- | ---: | ---: | ---: |
| `single_item` | 31.17 us | 7.35 us | 4.2x |
| `list_items` | 56.06 us | 17.06 us | 3.3x |
| `malformed_query` | 16.15 us | 2.46 us | 6.6x |
| `invalid_field` | 18.55 us | 4.30 us | 4.3x |
| `invalid_type` | 48.55 us | 4.73 us | 10.3x |
| `introspection` | 519.34 us | 133.51 us | 3.9x |

This table is the starting point for Engine V2, not a permanent benchmark fixture. Every milestone
will produce a new complete release-mode cross-runtime run.

Baseline metadata:

- Date: 2026-07-21.
- Host: Apple M5 Pro, arm64.
- OS: macOS 26.5.2 (25F84).
- Toolchain: Apple Swift 6.3.3 (`swiftlang-6.3.3.1.3`, `clang-2100.1.1.101`).
- GraphQL commit: `1099def` (`codex/executor-performance`).
- Graphiti commit: `0afff9b` (`codex/executor-performance`).
- Build mode: SwiftPM release.
- Run configuration: 500 warmups, 2,000 iterations per sample, 15 samples.
- Pipeline: parse, validate, execute, and materialize the ordinary public result.

## Progress Log

### 2026-07-21: Engine V2 scaffolding and lexer foundation

- Created branch `codex/engine-v2` from the optimized Engine V1 branch.
- Added the internal `GraphQLFast` target and `GraphQLFastTests` target.
- Established the dependency direction `GraphQLFast <- GraphQL <- Graphiti`.
- Added compact source ranges, arena ranges, and typed operation, selection, argument, and value
  arenas without per-node strings.
- Added a UTF-8 lexer whose tokens contain only a kind and source-byte range.
- The lexer reads contiguous `String.UTF8View` storage without copying when Swift exposes it and
  uses a contiguous fallback otherwise.
- Added differential token-kind and source-range tests against the Engine V1 lexer for operations,
  variables, fragments, numbers, strings, block strings, comments, commas, and BOM handling.
- Verification: `swift test --disable-sandbox --filter FastLexerTests` passed 7 tests, including 10
  parameterized Engine V1/Engine V2 differential cases.
- No Engine V2 code is connected to the public request path yet.

### 2026-07-21: Benchmark-document parser and microbenchmark harness

- Added an executable-document parser that produces typed, contiguous arenas linked by integer IDs.
- Added support for named and anonymous operations, nested fields, aliases, scalar arguments,
  variables used as values, fragment spreads, and inline fragments.
- Added structural normalization tests comparing Engine V1 and Engine V2 operation, selection,
  argument, value, and fragment trees.
- All six benchmark documents are covered: five structurally equivalent successful parses and one
  malformed document rejected by both engines.
- Added the release-only `graphql-fast-benchmarks` executable.
- The benchmark consumes token ranges and all populated document arenas through non-inlined
  checksum functions to prevent dead-code elimination.
- Command: `swift run -c release --disable-sandbox graphql-fast-benchmarks`.
- Configuration: 1,000 warmups, 10,000 iterations per sample, 15 samples.

| Raw boundary | Engine V1 | Engine V2 | Speedup |
| --- | ---: | ---: | ---: |
| Successful lex | 1,685.10 ns | 135.86 ns | 12.4x |
| Successful parse | 2,535.23 ns | 395.40 ns | 6.4x |
| Malformed parse | 4,242.18 ns | 320.07 ns | 13.3x |

These are internal parser-boundary measurements, not substitutes for the end-to-end benchmark.
Engine V2 does not yet adapt its compact parse errors into the public `GraphQLError` representation.
- Full regression verification after this milestone: 901 tests in 68 suites passed, including the
  original 891 GraphQL tests and 10 new Engine V2 test invocations.

### 2026-07-21: Broader executable grammar

- Added compact arenas for fragments, variable definitions, type references, directives, complex
  values, and object fields.
- Added variable defaults, nested list/non-null type references, directives on operations, fields,
  inline fragments, fragment spreads, fragments, and variable definitions.
- Added nested list and object values using linked arena entries rather than recursive object
  allocation.
- Added named fragment definitions and inline fragments without a type condition.
- Added a 15-document accepted/rejected differential corpus covering these features.
- The microbenchmark caught a 64% successful-parse regression caused by eagerly reserving five
  optional arenas. Making those arenas allocate only on first use reduced successful parsing from
  649.52 ns to 439.63 ns and malformed parsing from 466.18 ns to 318.29 ns.
- Post-expansion release measurements: 147.26 ns successful lex, 439.63 ns successful parse, and
  318.29 ns malformed parse.
- Full regression verification: 903 tests in 68 suites passed.
- Extended the differential corpus to 24 accepted/rejected executable documents drawn from the
  existing parser tests, including malformed fragment syntax, invalid operation names, const
  values containing variables, and empty selection sets.
- Engine V2 now parses the repository's existing executable `kitchen-sink.graphql` document.
- Corrected const-value parsing so variables are rejected in variable defaults while remaining
  valid in ordinary field arguments.
- Latest release measurements remained stable: 142.55 ns successful lex, 429.25 ns successful
  parse, and 310.82 ns malformed parse.
- Full regression verification after the corpus expansion: 904 tests in 68 suites passed.

### 2026-07-21: Public parser-error boundary

- Added compact parse errors carrying the found token and byte position needed for later adaptation.
- Added an SPI adapter that constructs the existing highlighted `GraphQLError` without connecting
  Engine V2 to the public request path.
- Added exact message, byte-position, and line/column parity tests for representative missing-name,
  unterminated-selection, and invalid-operation failures.
- Split malformed parsing into raw and public-error-adapted microbenchmarks.

| Malformed parser boundary | Median |
| --- | ---: |
| Engine V1 public parser failure | 4,223.71 ns |
| Engine V2 raw parser failure | 310.56 ns |
| Engine V2 with public `GraphQLError` | 3,190.77 ns |

The compact parser is 13.6x faster at identifying the failure, but existing highlighted error
construction adds approximately 2.88 us and now dominates the Engine V2 malformed path. Public
error formatting must therefore receive its own optimization work before end-to-end cutover.

Follow-up optimization replaced the regular-expression source scans at the Engine V2 adapter with
a single-pass formatter and a precomputed-location `GraphQLError` initializer. Exact public parity
coverage now includes CRLF input and Unicode before the failure as well as the original cases.

| Optimized malformed parser boundary | Median |
| --- | ---: |
| Engine V1 public parser failure | 4,369.17 ns |
| Engine V2 raw parser failure | 309.86 ns |
| Engine V2 with public `GraphQLError` | 1,114.14 ns |

Public error materialization now adds approximately 804 ns instead of 2.88 us. This measurement is
below the current 2.52 us Rust end-to-end malformed-query baseline, but Engine V2 is not connected
to the complete request path yet, so it is not an end-to-end victory claim.

### 2026-07-21: Lazy string-value decoding

- Added on-demand decoding for ordinary and block string values without adding allocated strings
  to the compact parser arenas.
- Ordinary unescaped strings decode directly from the source's contiguous UTF-8 storage. Escapes,
  Unicode escapes, block indentation normalization, and escaped triple quotes are processed only
  when a consumer requests the value.
- Added differential tests against Engine V1 for seven ordinary and block-string cases, including
  mixed CRLF/CR newline forms, plus invalid-access tests.
- Added separate release microbenchmarks so this semantic boundary remains visible rather than
  being folded invisibly into parser timing.

| Engine V2 string boundary | Median |
| --- | ---: |
| Plain string decode | 7.81 ns |
| Escaped string decode | 191.80 ns |
| Block string decode and normalization | 335.32 ns |

The same release run measured successful parsing at 430.23 ns, parsing plus the required plain
string decode at 433.86 ns, and raw malformed parsing at 310.34 ns. Adding the lazy accessor did
not regress the compact parser hot path. Engine V1, whose lexer eagerly decodes token values,
measured 2,587.04 ns at the directly comparable successful-parse boundary.
- Full regression verification after the public-error and lazy-string milestones: 907 tests in 69
  suites passed.

### 2026-07-21: Phase 1 closeout

- Added 24 generated valid executable documents covering all operation kinds, variables, nested
  selections, fragments, directives, scalar values, and container values. Engine V1 and Engine V2
  produce equivalent normalized structures for every document.
- Added a deterministic mutation corpus containing 763 byte deletion and punctuation-replacement
  variants of representative executable documents. Engine V1 and Engine V2 agree on acceptance
  or rejection for every mutation.
- Expanded exact public parser-error parity to 14 cases and exact public lexer-error parity to 15
  cases. Coverage includes every compact lexical failure variant, parser token and keyword errors,
  EOF positioning, number details, escapes, ordinary and block strings, Unicode, LF, and CRLF.
- The expanded error corpus found and corrected three parser error-state mismatches plus incomplete
  lexical error payloads and incorrect unterminated-string positions.
- Full regression verification: 910 tests in 69 suites passed.

| Phase 1 closeout boundary | Engine V1 | Engine V2 | Speedup |
| --- | ---: | ---: | ---: |
| Successful lex | 1,743.19 ns | 151.05 ns | 11.5x |
| Successful parse | 2,763.07 ns | 441.04 ns | 6.3x |
| Malformed parse, raw | 4,688.76 ns | 329.94 ns | 14.2x |
| Malformed parse, public error | 4,688.76 ns | 1,198.47 ns | 3.9x |

Phase 1 is complete. Engine V2 remains disconnected from the public request path; Phase 2 will
compile the existing authoritative schema into immutable numeric tables.

### 2026-07-21: Phase 2 numeric schema foundation

- Added fixed-width IDs and dense tables for interned names, named types, fields, input values, and
  wrapped type references in the dependency-free `GraphQLFast` target.
- Added a `GraphQL` adapter that compiles the existing authoritative schema into fast metadata plus
  aligned named-type, field-definition, and default-value side tables.
- Added a schema-lifetime cache protected during initialization; the resulting compiled value is
  one immutable reference object and requires no synchronization for reads.
- Added correctness coverage for every named type kind, root operation IDs, field and type lookup,
  arguments, defaults, nested list/non-null shapes, backing-store cache reuse, and 32-task
  concurrent reads.
- Full regression verification: 913 tests in 70 suites passed.

| Schema boundary | Engine V1 | Engine V2 |
| --- | ---: | ---: |
| Cold metadata compilation | n/a | 16,448.55 ns |
| Cached-view acquisition | n/a | 185.49 ns |
| Type lookup by existing `String` | 9.34 ns | 10.05 ns |
| Field lookup by existing `String` | 23.38 ns | 18.80 ns |

Cold compilation is a one-time schema cost. Cached-view acquisition must occur at request setup,
not per field. Phase 3 request compilation will add source-range/hash lookup that avoids allocating
temporary strings; the current string-keyed lookup exists for adapter verification and baseline
comparison.

The initial lookup harness gave Engine V2 an extra non-inlined consumption call, and the compiled
schema was initially a large value struct while Engine V1 passed a class reference. Correcting the
harness and using an immutable schema-lifetime reference reduced type lookup from 11.89 ns to
10.05 ns and cached acquisition from 245.24 ns to 185.49 ns. The remaining 0.71 ns type-lookup
difference is specific to temporary `String` dictionary lookup and is not the Phase 3 request path.

### 2026-07-21: Phase 2 abstract-type and directive metadata

- Added compact membership arenas for object interfaces, interface implementations, and union
  members. Abstract-type checks now operate on numeric IDs without schema dictionary lookups or
  lazy subtype-cache synchronization.
- Added dense enum-value records and directive records containing arguments, location bitsets, and
  repeatability. Existing definitions and default values remain available through aligned side
  tables in the `GraphQL` adapter.
- Added correctness coverage for object/interface relationships, interface and union possible
  types, enum values, built-in directive arguments, and directive locations.
- Full regression verification: 913 tests in 70 suites passed.

| Abstract-type boundary | Engine V1 | Engine V2 | Speedup |
| --- | ---: | ---: | ---: |
| Possible-type check | 275.12 ns | 1.52 ns | 181.0x |

The benchmark alternates a matching and nonmatching concrete type so the optimizer cannot hoist a
constant result. It currently uses a one-member union and isolates only membership testing: Engine
V1 performs string-based schema lookups and accesses its synchronized lazy subtype cache, while
Engine V2 scans a precompiled numeric range. This is evidence for the representation, not an
end-to-end request speedup claim. The expanded benchmark schema now compiles in 22,708.95 ns and
cached-view acquisition is 197.46 ns; these figures are not directly comparable with the earlier
smaller schema fixture.

The next Phase 2 slice will classify the existing field resolver forms and store direct resolver
thunks alongside compiled field metadata, followed by compilation across the broader test-schema
corpus and explicit fallback classification for unsupported behavior.

## Phase 0: Baseline and Contracts

Before implementing the new engine:

- Preserve the current benchmark result as the Engine V1 baseline.
- Add component timing for parsing, validation/compilation, execution, and result conversion.
- Record allocations, ARC traffic, and peak memory.
- Establish differential-test helpers that run requests through both engines.
- Define which error properties must match exactly:
  - Message
  - Source locations
  - Response paths
  - Null propagation
  - Error ordering

### Exit criteria

- The benchmark can report component timings without changing its normal end-to-end cases.
- A reusable differential test harness can compare normalized Engine V1 and Engine V2 outcomes.
- The baseline is reproducible in release mode.

## Phase 1: Compact Executable-Document Parser

Implement an executable GraphQL parser in `GraphQLFast` that:

- Operates directly on UTF-8 bytes.
- Stores names as source ranges or interned numeric IDs.
- Uses contiguous arrays for nodes.
- Represents relationships with integer indices.
- Avoids allocating a class or protocol existential for every AST node.
- Tracks source positions as integer byte offsets.
- Defers line/column calculation and highlighted errors until requested.
- Parses executable documents only at first; schema SDL remains on Engine V1.

### Feature order

1. Operations and selection sets.
2. Fields and aliases.
3. Scalar arguments.
4. Variables and type references.
5. Inline fragments.
6. Named fragments.
7. Directives.
8. List and object values.

### Correctness gates

- Differential tests against the existing parser.
- Coverage from the existing parser corpus.
- Generated and fuzzed documents.
- Equivalent accepted and rejected inputs.
- Equivalent source offsets and public error locations.

### Performance gate

Attack `malformed_query` first. The intermediate target is approximately 3 us per request before
proceeding to the compiled validator, with remaining differences addressed through profiling.

## Phase 2: Compiled Schema Representation

Compile each existing `GraphQLSchema` once into immutable fast-engine tables containing:

- Numeric type IDs.
- Numeric field IDs.
- Interned schema names.
- Dense field and type arrays.
- Precomputed wrapped-type shapes.
- Precomputed nullability and list information.
- Precomputed argument definitions and default values.
- Precomputed interface and union membership.
- Precomputed introspection metadata.
- Resolver thunks stored directly on field records.

The existing schema remains authoritative. The fast schema is an internal compiled view cached for
the lifetime of the schema.

### Correctness gates

- Every existing test schema can be compiled or is explicitly classified as unsupported.
- Compilation never silently changes schema semantics.
- Unsupported custom behavior routes to Engine V1.
- Concurrent reads of the compiled schema require no locking.

## Phase 3: Fused Validation and Plan Compilation

Replace the general visitor-based request path with one schema-aware traversal that:

- Resolves operation and fragment references.
- Resolves names to numeric schema IDs.
- Validates fields, arguments, variables, directives, and type conditions.
- Detects fragment cycles.
- Produces the executable selection plan directly.
- Records only source information required for possible errors.

There should be no intermediate generic validation context, generic parallel visitor graph, or
second schema lookup during execution.

### Optimization order

1. `invalid_type`.
2. `invalid_field`.
3. `single_item`.
4. Introspection validation.

### Correctness gates

- Differential validation across the existing validation suite.
- Equivalent error messages, locations, and ordering where part of the current contract.
- Custom validation rules continue to use Engine V1 initially.
- Documents using an unsupported validation feature fall back before invoking resolvers.

## Phase 4: Typed Resolver Dispatch

Introduce fast-engine resolver thunks generated while adapting the schema:

- Separate synchronous and asynchronous thunk types.
- Concrete field and type metadata captured during schema compilation.
- No `any Sendable` traffic within ordinary scalar completion.
- No `GraphQLResolveInfo` construction unless the resolver requires it.
- No response-path allocation unless an error path is required.
- Arguments decoded directly from the compiled request representation.
- Key-path fields use the shortest specialized route.

The synchronous executor must not enter Swift concurrency machinery. Encountering an asynchronous
resolver switches to an asynchronous continuation without changing observable semantics.

### Correctness gates

- Resolver invocation counts and ordering match Engine V1.
- Async, throwing, nullable, and non-null resolver tests pass.
- Mutations remain serial.
- Query concurrency and cancellation semantics are explicitly tested.
- Resolver errors retain correct source locations and response paths.

## Phase 5: Arena-Backed Result Construction

Create an internal result representation using contiguous request-owned storage:

- Scalar nodes stored inline where practical.
- Object fields represented as contiguous ranges.
- List items represented as contiguous ranges.
- No separate reference-counted allocation for each nested result node.
- Error paths stored compactly as numeric components.
- Conversion to the existing public `Map` and `GraphQLResult` representation occurs once at the API
  boundary.

This phase primarily targets `list_items`, `introspection`, ARC overhead, and result-destruction
costs.

Internal execution and public-result conversion will be measured separately. The published
benchmark continues timing the ordinary public result so comparisons remain honest.

## Phase 6: Compiled Introspection

Build introspection over the compiled schema tables using:

- Pre-sorted type and field collections.
- Precomputed type kinds.
- Direct wrapped-type relationships.
- Precomputed directive locations.
- Cached scalar representations for static metadata.
- Normal compiled execution plans for arbitrary introspection selections.

No Swift reflection should occur in the Engine V2 introspection path.

## Phase 7: Controlled Cutover

Introduce an internal engine policy:

```swift
enum GraphQLEnginePolicy {
    case reference
    case fast
    case automatic
    case verify
}
```

- `reference`: Engine V1 only.
- `fast`: Engine V2 only and report unsupported features rather than falling back.
- `automatic`: Engine V2 with transparent fallback to Engine V1.
- `verify`: Run both engines and compare normalized results in tests and debugging.

### Cutover sequence

1. Benchmark adapter.
2. Opt-in internal applications.
3. Default for supported queries.
4. Progressive feature expansion.
5. Removal of individual fallbacks only when their correctness coverage is equivalent.

The public `graphql(...)`, Graphiti `Schema.execute`, subscription, and prepared-operation APIs
remain source compatible.

## Testing Strategy

Every milestone must pass three layers:

1. Unit tests for the new representation and algorithms.
2. Differential tests against Engine V1.
3. Existing GraphQL and Graphiti regression suites.

Additional testing will include:

- Property-based executable-document generation.
- Parser and validator fuzzing.
- Random schemas and operations.
- Async cancellation and concurrency tests.
- Null propagation and error-path tests.
- Allocation and performance regression thresholds in release mode.

Performance changes will not be accepted by weakening validation, omitting result materialization,
changing required error behavior, or adding query caching unavailable to the other benchmark
implementations.

## Benchmark Progression

| Milestone | Cases expected to improve |
| --- | --- |
| Compact parser | `malformed_query`, with modest improvements elsewhere |
| Fused validator/compiler | `invalid_field`, `invalid_type`, and all valid queries |
| Numeric schema and typed dispatch | `single_item` |
| Result arena | `list_items` and `introspection` |
| Compiled introspection | `introspection` |
| ARC and specialization pass | Remaining gap across all cases |

After every milestone, run the complete cross-runtime release suite, not only isolated
microbenchmarks.

## Initial Implementation Milestone

The first implementation slice will be:

- [x] Create the `GraphQLFast` target and its test target.
- [x] Define the compact executable-document storage format.
- [x] Implement the UTF-8 lexer.
- [x] Implement enough parser coverage for all six benchmark documents.
- [x] Differential-test the six benchmark documents.
- [x] Differential-test the broader existing executable-document parser corpus.
- [x] Add parse-only measurements to the benchmark harness.
- [x] Optimize until the malformed-query path is materially closer to Rust.

Only after the parser representation proves both correctness and performance will the compiled
schema and fused validator be built on top of it.

## Working Principles

- Optimize measured costs rather than presumed costs.
- Keep Engine V1 executable until Engine V2 has equivalent coverage.
- Prefer compact immutable data over object graphs and string-keyed lookup.
- Preserve synchronous execution as a truly synchronous path.
- Make unsupported behavior explicit and observable.
- Commit small milestones with benchmark and correctness evidence.
- Treat public API compatibility and GraphQL semantics as hard constraints.
