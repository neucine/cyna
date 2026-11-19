# Cyna documentation

This repository contains the canonical language contract and public documentation for Cyna users.

- [Specification](SPEC.md): normative language rules.
- [Terminology](GLOSSARY.md): canonical names for language and ownership concepts.
- [Semantics](SEMANTICS.md): core invariants and the canonical ownership and place model.
- [Guide](GUIDE.md) and [cheatsheet](CHEATSHEET.md): supported patterns and examples.
- [Build](BUILD.md), [runtime](RUNTIME.md), and [toolchain](TOOLCHAIN.md): current toolchain. Build covers package commands, manifests, and dependencies; the spec covers import rules.
- [CI](CI.md): default macOS quick checks and how to opt in to Linux and Windows checks.
- [Concurrency](CONCURRENCY.md): current thread, synchronization, and task contracts.
- [Cryptography](CRYPTO.md): SHA-256 and HMAC-SHA-256 usage and limits.
- [Byte input and output](IO.md): reader and writer contracts and bounded helpers.
- [Status](STATUS.md): implemented features and known limitations.
- [Philosophy](PHILOSOPHY.md): language goals.

`SPEC.md` is authoritative for language behavior. If another document disagrees, update it to match the spec and compiler. Internal design and engineering records live in the central daydream repository.
