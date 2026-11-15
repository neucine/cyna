# Evaluation Order Coverage

Spec target: `docs/SPEC.md` section 21.

## Current Coverage

- struct-literal field expressions evaluate in source order while values are
  placed into declaration-ordered layout slots

## Sufficient Coverage Bar

- observable expression order is normative
- side-effecting characterization cases protect the accepted order
- a proposal that changes order retains the old case as migration evidence

## Known Gaps

- add focused cases for call arguments, sequence literals, keyed container
  literals, binary operands, and assignment evaluation as those rules are made
  normative
