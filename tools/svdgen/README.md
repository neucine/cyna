# Cyna SVD Generator

`svdgen` converts CMSIS-SVD files into Cyna SoC modules that use
`embedded.hal.mmio`.

```sh
cd tools/svdgen
go run . -i path/to/chip.svd -o ../../packages/embedded/src/soc/vendor/chip/device.cy -soc ChipName
```

The generator emits a device module:

- device-level SVD metadata such as vendor and register width
- one struct per peripheral
- one fixed-address register constant for each register
- one nested packed struct per register, inside its peripheral
- `mmio.Reg32`, `mmio.Reg32RO`, `mmio.Reg32WO`, or fallback raw-width register types based on SVD access
- reserved bit fields for gaps
- `enum` for ordinary field enumerations
- `flags` only when explicitly enabled and inferred from bitset-like values
- expanded register and cluster arrays
- common `derivedFrom` inheritance for peripherals, registers, clusters, fields,
  and enumerated values
- warnings for malformed SVD fields that overlap or exceed the register width

The generated file is intended to be mapped by the package manifest under an
`embedded.soc.*` module path. For a SoC with hand-written support files, keep the
generated SVD output in a folder such as `soc/sifive/fe310/device.cy` and add
other modules next to it.
