# Cyna Philosophy

Cyna is built on the belief that most software problems do not need more ways
to express the same idea. They need clearer defaults, tighter boundaries, and
fewer moving parts.

The project prefers discipline over freedom, conventions over configuration,
and explicitness over abstraction.

## Core Position

Cyna does not try to be infinitely flexible.

Instead, it aims to make the common systems-programming path:

- obvious
- explicit
- small
- predictable

When a capability is rare, highly style-dependent, or mainly useful as a way
to support many competing approaches, it should stay out of the core language
and tooling unless it clearly pays for its cost.

## What This Means For The Language

The language should stay small and direct:

- few features with clear roles
- explicit ownership and cleanup boundaries
- minimal hidden behavior
- no pressure to support many equivalent styles

Cyna should not add language features just because other languages have them,
or because they make it easier to express custom patterns that good defaults
already cover well enough.

Cyna should also avoid speculative abstraction. A feature that exists mainly to
preserve future flexibility can still impose permanent cost on the compiler,
diagnostics, documentation, tooling, and ordinary readers. Promised
extensibility is not free just because the uncommon case never arrives.

Before adding a feature, Cyna should ask what concrete, recurring problem is
painful today, whether explicit existing mechanisms already handle it well
enough, and whether ordinary programs would pay complexity cost for unusual
programs.

The burden of proof is highest for broad extension points, multiple equivalent
styles, implicit behavior, and long-term compatibility obligations.

## What This Means For The Build System

The build system should describe intent, not process:

- no programmable build DSL
- no user-defined control flow in manifests
- no large orchestration surface for arbitrary build styles
- first-class support only for common native needs such as outputs, libraries,
  C sources, assembly sources, include paths, and linker settings

If a build need is common, Cyna should expose it as a small declarative field.
If it is unusual, external tools are better than growing a second language
inside the build system.

## What This Means For The Standard Library

The standard library should be practical and compact:

- include what most users repeatedly need
- avoid duplicate abstractions that differ mainly by style
- avoid convenience layers that hide cost or policy
- prefer simple primitives over broad frameworks

Cyna does not aim to ship a huge standard library full of rarely used
facilities just to reduce short-term friction at the cost of long-term
complexity.

## Constraint As A Feature

This philosophy is not about removing power for its own sake.

It is about making the right path easy to recognize and easy to trust. A small
number of strong conventions often scales better than a large number of weakly
guided extension points.

The goal is not maximum freedom.
The goal is a language and toolchain that stay coherent as they grow.
