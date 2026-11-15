# Generics Coverage

Design target: `projects/cyna/docs/architecture/GENERICS_PROTOCOLS.md` in daydream.

Implementation/spec target: `docs/SPEC.md` section 22.

## Current Coverage

Carried-forward execution tests cover:

- generic C-layout structs
- explicit protocol conformance
- generic declaration validation
- protocol constraints at function, struct, and method instantiation
- generic structs and functions
- explicit and inferred method type arguments
- nested argument inference
- generic methods with ownership/provenance-sensitive receivers and arguments
- explicit `Eq` conformance enabling `Set<T>` elements and `Map<K, V>` keys
  without making concrete `==` protocol-backed
- core generic `.eq(...)` calls for primitive values and `char`
- intentional missing-`Eq` rejection for enum, flags, raw-pointer, fixed-array,
  alias-pointer, and owned-sequence collection keys
- the inability of enum declarations to own an ordinary protocol `impl`
- ownership-safe generic `Eq` through borrowed sparse capture for a
  resource-bearing value
- resource-bearing Set/Map keys across duplicate insertion, growth, lookup, and
  replacement
- resource-bearing Set/Map literals, independent collection copies, clear and
  reuse, and copyable value snapshots
- semantic rejection of by-value resource indexing/iteration and
  resource-bearing selected key/value snapshots before lowering
- CLI/LSP ownership of missing-bound and resource-snapshot diagnostics
- stable generic iterator-hook symbols through SIR and LIR lowering

Negative cases currently live in the semantic negative collection:

- missing protocol methods
- wrong receiver type
- non-protocol constraints
- unknown protocols
- nonconforming call-site types

## Sufficient Coverage Bar

- Surface: generic declarations, type arguments, method type arguments, and
  parse ambiguity with comparison operators.
- Semantics: constraints resolve to protocols, implementations conform, type
  arguments infer correctly, and invalid constraints fail with diagnostics.
- Execution: instantiated generic functions, structs, and methods behave like
  concrete code.
- Ownership: generic methods preserve borrow/provenance summaries without
  receiver or argument pollution.
- Diagnostics: common constraint and conformance failures report useful
  messages.

## Known Gaps

- Split surface parsing tests from native execution tests.
- Move generics/protocol negative cases from the broad negative table into this
  feature folder.
- Add diagnostic-substring coverage for common generic mistakes.
- Add non-native semantic-only tests for declaration validation that does not
  need execution.
- Add target coverage only if monomorphized layout or ABI behavior differs by
  target.
