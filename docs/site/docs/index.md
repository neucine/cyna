---
layout: home
title: Cyna systems programming language

hero:
  text: Cyna 0.5.3
  tagline: Clear value behavior, explicit ownership, and practical low-level control.
  actions:
    - theme: brand
      text: Get Started
      link: /toolchain.html
    - theme: alt
      text: Build Docs
      link: /build.html

features:
  - title: Explicit by design
    details: Ownership handoff and `unchecked` boundaries stay visible.
  - title: One language for ownership
    details: Plain, shared, and owned describe value behavior; borrow, clone, and handoff name the operations.
  - title: Familiar to C programmers
    details: Direct C ABI work uses `c struct`, `c union`, `c enum`, `extern c`, `export c`, and generated headers.
  - title: Small coherent toolchain
    details: The language, build system, and standard library aim for one practical style instead of parallel feature families.
  - title: Value shapes first
    details: Lists, maps, sets, optionals, typed error returns, slices, aliases, and pointers have distinct roles.
  - title: Predictable cleanup
    details: Native lowering already covers ownership-driven cleanup, `drop`, `defer`, and the current `take` model.
  - title: Readable low-level control
    details: You can inspect emitted LIR and LLVM artifacts when you need to see what the compiler produced.
---
