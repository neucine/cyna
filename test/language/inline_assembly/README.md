# Inline Assembly

Spec coverage target: section 24.1 in `docs/SPEC.md`.

Missing feature-folder coverage should include inline assembly syntax,
placeholders, inputs, outputs, tied operands, clobbers, target validation, and
unchecked-boundary requirements.

Current files:

- `sema.zig`: carried-forward semantic and diagnostic tests
- `suite.zig`: feature suite import root
