# Pointers

Coverage target: alias pointers, owned pointers, raw pointers, unchecked
requirements, volatile pointer access, and pointer boundary behavior.

Sufficient coverage includes safe pointer use, unsafe rejection diagnostics,
unchecked escape hatches, and representative execution behavior.

Current files:

- `exec.zig`: carried-forward pointer execution and semantic tests
- `suite.zig`: feature suite import root
