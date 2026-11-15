.syntax unified
.thumb

.section .text._start, "ax", %progbits
.global _start
.type _start, %function

_start:
    bl cyna_entry

1:
    b 1b
