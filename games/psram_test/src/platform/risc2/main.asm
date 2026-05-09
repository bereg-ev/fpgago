; main.asm — PSRAM controller unit test
;
; Writes two 32-bit patterns into the PSRAM region (0x100000+), reads them
; back, and reports the result over UART:
;   'P' = pass (both patterns match)
;   'F' = fail (first mismatch)
; Sender spins on the result so the testbench can latch it any time.
;
; Register convention (caller-saved unless noted):
;   r0 = scratch (UART address)
;   r1 = byte to send
;   r2 = scratch (UART status)
;   r3 = address being tested
;   r4 = pattern to write
;   r5 = pattern read back
;   r6 = expected pattern (for compare)
;   r14 = SP, set up by startup.s (= 0x01FF00)
;   r15 = LR, set by CALL

main:
    ; ------------------------------------------------------------------
    ; WRITE PHASE
    ; ------------------------------------------------------------------

    ; PSRAM[0x100000] <- 0xDEADBEEF
    imm   #1
    mov   r3, #0
    imm   #dea
    mov   r4, #dbeef
    store (r3), r4

    ; PSRAM[0x100100] <- 0xCAFEBABE
    imm   #1
    mov   r3, #100
    imm   #caf
    mov   r4, #ebabe
    store (r3), r4

    ; ------------------------------------------------------------------
    ; READ-BACK PHASE
    ; ------------------------------------------------------------------

    ; Test 1: PSRAM[0x100000] should be 0xDEADBEEF
    imm   #1
    mov   r3, #0
    load  r5, (r3)
    imm   #dea
    mov   r6, #dbeef
    cmp   r5, r6
    jnz   fail

    ; Test 2: PSRAM[0x100100] should be 0xCAFEBABE
    imm   #1
    mov   r3, #100
    load  r5, (r3)
    imm   #caf
    mov   r6, #ebabe
    cmp   r5, r6
    jnz   fail

    ; All compares passed
pass:
    mov   r1, #50              ; 'P'
    call  uart_send
    jmp   pass                 ; resend forever so the harness always sees it

fail:
    mov   r1, #46              ; 'F'
    call  uart_send
    jmp   fail

; ------------------------------------------------------------------
; uart_send: r1 = byte to transmit.  Spins until UART_STATUS.txbusy
; clears, then writes the byte to UART_TX.
;   UART_STATUS = 0x008100, txbusy = bit 2 (mask 0x04)
;   UART_TX     = 0x008104
; ------------------------------------------------------------------
uart_send:
    mov   r0, #8100
us_wait:
    load  r2, (r0)
    and   r2, #4
    jnz   us_wait
    mov   r0, #8104
    store (r0), r1
    ret
