ENTRY(_start)

SECTIONS
{
  . = 0x08000000;

  .text :
  {
    KEEP(*(.text._start))
    *(.text*)
    *(.rodata*)
  }

  .data :
  {
    *(.data*)
  }

  .bss (NOLOAD) :
  {
    *(.bss*)
    *(COMMON)
  }
}
