# Symbols

Coverage target: imported symbols, exported symbols, ABI names, duplicate
symbol rejection, visibility, and module-qualified symbol resolution.

Sufficient coverage includes accept/reject tests, diagnostic substrings, and
link-time or C roundtrip checks where symbol behavior is observable.

Mixed keyword/attribute import-export pairs are covered as one effective symbol
identity rather than separate ABI systems.
