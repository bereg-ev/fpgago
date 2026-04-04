; startup.s — RISC2 startup (shared by all games)
;
; Address 0x00: reset vector    → jmp start
; Address 0x04: timer IRQ (1)   → jmp timerirq
; Addresses 0x08..0x1C: unused IRQ vectors (nop padding)
;
; Stack at top of data RAM: 0x01FF00

    jmp   start
    jmp   timerirq
    nop
    nop
    nop
    nop
    nop
    nop

timerirq:
    iret

start:
    mov   r14, #1ff00       ; SP = 0x01FF00

    ; --- boot diagnostic: send '!' to UART (visible in Verilator terminal) ---
    mov   r0, #f0003
    mov   r1, #21            ; '!'
    store (r0), r1
    ; -------------------------------------------------------------------------

    call  main

hang:
    jmp   hang
