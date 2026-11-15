# Pointer Ownership Coverage

Spec target: `docs/SPEC.md` sections 11.1, 11.3, 11.5, 11.6, 12, and 12.1.

## Current Coverage

Carried-forward tests cover:

- owned pointer borrow and handoff
- raw pointer and volatile raw pointer type declarations
- raw and volatile pointer dereference inside `unchecked`
- volatile packed field reads and writes
- integer reinterpretation to and from volatile raw pointers
- raw pointer dereference rejection outside `unchecked`
- raw pointer assignment and field/indexed-field assignment inside `unchecked`
- raw pointer assignment rejection outside `unchecked`
- typed raw pointer `p + n` scales by the pointee size, preserves `*const`
  pointee type, and rejects use outside `unchecked` or on `*c_void`

## Sufficient Coverage Bar

- Surface: pointer type forms parse and unsafe operations require `unchecked`.
- Semantics: pointer conversions, dereference, assignment, and volatile access
  are accepted or rejected according to safety boundaries.
- Execution: representative raw pointer operations mutate/read expected values
  when explicitly unchecked.
- Diagnostics: unsafe operations outside `unchecked` report useful messages.
- Target: volatile/raw pointer reinterpretation is checked where target pointer
  width matters.

## Known Gaps

- Add diagnostic-substring tests for all unsafe pointer parse/semantic
  rejections.
- Add target-width-sensitive pointer reinterpretation tests.
- Split volatile/MMIO behavior if it grows beyond pointer ownership.
