/* link.ld — linker script for the labyrinth firmware on DarkRISCV.
 *
 * Matches the SoC address map in soc.v.
 *
 *   ROM at 0x00000000 (64 KB) — .text + .rodata + .data (LMA)
 *   RAM at 0x00010000 (32 KB) — .data (VMA after startup copy) + .bss + stack
 *   FB  at 0x00100000 (1 MB)  — referenced as a fixed pointer in C, not by linker.
 *
 * RAM shrank from 64 KB → 32 KB so the design fits ECP5-25F BRAM.  trig
 * tables and brick texture are now `const` so they live in ROM, not RAM.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    ROM (rx)  : ORIGIN = 0x00000000, LENGTH = 64K
    RAM (rwx) : ORIGIN = 0x00010000, LENGTH = 32K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.init))         /* startup.s _start vector */
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
        _etext = .;
    } > ROM

    /* .data: contents stored in ROM (LMA), copied to RAM (VMA) by _start. */
    .data : AT(_etext) {
        _sdata = .;
        *(.data*)
        *(.sdata*)
        . = ALIGN(4);
        PROVIDE(__global_pointer$ = . + 0x800);
        _edata = .;
    } > RAM

    .bss (NOLOAD) : {
        _sbss = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        _ebss = .;
    } > RAM

    /* Stack at the very top of RAM, growing down. */
    _stack_top = ORIGIN(RAM) + LENGTH(RAM);
}
