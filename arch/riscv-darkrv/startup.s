# startup.s — RISC-V (RV32I) reset vector + .data copy + .bss zero + main().
#
# The CPU starts at PC=0, which is where this section lands (KEEP'd by link.ld).

    .section .text.init, "ax"
    .global _start
_start:
    # Stack pointer = top of RAM
    la      sp, _stack_top

    # Global pointer (optional but riscv-gcc emits ".option norelax" without it)
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    # Copy .data from ROM (LMA) to RAM (VMA)
    la      t0, _sdata          # dest in RAM
    la      t1, _edata
    la      t2, _etext          # source in ROM (LMA of .data)
1:
    beq     t0, t1, 2f
    lw      t3, 0(t2)
    sw      t3, 0(t0)
    addi    t0, t0, 4
    addi    t2, t2, 4
    j       1b
2:

    # Zero .bss
    la      t0, _sbss
    la      t1, _ebss
3:
    beq     t0, t1, 4f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       3b
4:

    # Jump to main()
    call    main

    # Halt — should never reach here
hang:
    j       hang
