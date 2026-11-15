# Language Feature Test Map

This directory is organized around user-visible language features from
`docs/SPEC.md`, not compiler phases.

Feature folders may start with only a placeholder while coverage is migrated
from older phase-oriented suites. A feature folder should eventually collect
surface, semantic, execution, and target-specific cases for that feature.

Current carried-forward feature files:

- `generics/exec.zig`
- `declarations/exec.zig`
- `evaluation_order/characterization.zig`
- `integer_behavior/casts.zig`
- `integer_behavior/literals.zig`
- `unions_result/exec.zig`
