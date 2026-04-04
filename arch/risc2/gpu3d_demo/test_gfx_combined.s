; startup.s - RISC2 startup for gpu3d C demo
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
    mov   r14, #1ff00       ; stack pointer
    call  main
hang:
    jmp   hang
; runtime.s - RISC2 software runtime library for gpu3d demo
;
; ABI: r0,r1 = args/return; r2-r7 caller-saved; r8-r13 callee-saved
;      r14 = SP; r15 = LR (set by CALL)
;
; ALU: RCL rA,rB => rA = rB<<1, carry=rB[31]
;      RCR rA,rB => rA = {carry, rB[31:1]}, carry=0
;      MOV/AND/OR/XOR clear carry; ADD/SUB set carry on overflow/borrow

; -- __mulsi3: r0 = r0 * r1 --------------------------------------------------
__mulsi3:
    mov   r2, #0
_mul_loop:
    cmp   r1, #0
    jz    _mul_done
    mov   r3, r1
    and   r3, #1
    cmp   r3, #0
    jz    _mul_skip
    add   r2, r0
_mul_skip:
    rcl   r0, r0            ; r0 <<= 1
    and   r3, r3            ; clear carry so rcr zero-fills MSB
    rcr   r1, r1            ; r1 >>= 1 (logical)
    jmp   _mul_loop
_mul_done:
    mov   r0, r2
    ret

; -- __ashlsi3: r0 = r0 << r1 ------------------------------------------------
__ashlsi3:
    cmp   r1, #0
    jz    _shl_done
_shl_loop:
    rcl   r0, r0
    sub   r1, #1
    jnz   _shl_loop
_shl_done:
    ret

; -- __lshrsi3: r0 = r0 >> r1 (logical) --------------------------------------
__lshrsi3:
    cmp   r1, #0
    jz    _lshr_done
_lshr_loop:
    and   r0, r0            ; clear carry
    rcr   r0, r0            ; r0 >>= 1, 0 -> MSB
    sub   r1, #1
    jnz   _lshr_loop
_lshr_done:
    ret

; -- __ashrsi3: r0 = r0 >> r1 (arithmetic) -----------------------------------
__ashrsi3:
    cmp   r1, #0
    jz    _ashr_done
_ashr_loop:
    mov   r2, r0            ; carry = 0 (MOV clears carry)
    add   r2, r2            ; carry = MSB of r0 (sign bit)
    rcr   r0, r0            ; r0 >>= 1, sign -> MSB
    sub   r1, #1
    jnz   _ashr_loop
_ashr_done:
    ret

; -- __udivsi3: r0 = r0 / r1 (unsigned) --------------------------------------
__udivsi3:
    mov   r2, #0            ; remainder
    mov   r3, #32           ; bit counter
    mov   r4, #0            ; quotient
_udiv_loop:
    cmp   r3, #0
    jz    _udiv_done
    sub   r3, #1
    add   r2, r2            ; remainder <<= 1
    add   r0, r0            ; dividend <<= 1; carry = old MSB
    jnc   _udiv_no_msb
    or    r2, #1            ; remainder |= 1
_udiv_no_msb:
    add   r4, r4            ; quotient <<= 1
    cmp   r2, r1
    jc    _udiv_loop         ; if remainder < divisor: skip
    sub   r2, r1            ; remainder -= divisor
    or    r4, #1            ; quotient  |= 1
    jmp   _udiv_loop
_udiv_done:
    mov   r0, r4
    ret

; -- __divsi3: r0 = r0 / r1 (signed) -----------------------------------------
; Saves r15 since we call __udivsi3.
__divsi3:
    sub   r14, #8
    store (r14), r15         ; save return address
    mov   r6, r14
    add   r6, #4
    store (r6), r7           ; save r7

    mov   r7, #0             ; sign flag

    ; negate r0 if negative
    mov   r2, r0
    add   r2, r2            ; carry = MSB of r0
    jnc   _divs_num_pos
    mov   r2, #0
    sub   r2, r0
    mov   r0, r2
    xor   r7, #1
_divs_num_pos:
    ; negate r1 if negative
    mov   r2, r1
    add   r2, r2            ; carry = MSB of r1
    jnc   _divs_den_pos
    mov   r2, #0
    sub   r2, r1
    mov   r1, r2
    xor   r7, #1
_divs_den_pos:
    call  __udivsi3

    ; negate result if signs differed
    cmp   r7, #0
    jz    _divs_done
    mov   r2, #0
    sub   r2, r0
    mov   r0, r2
_divs_done:
    load  r15, (r14)
    mov   r6, r14
    add   r6, #4
    load  r7, (r6)
    add   r14, #8
    ret
main:                                   ; -- Begin function main
                                        ; @main
; %bb.0:                                ; %entry
	sub r14, #4
	mov r0, #c0000
	mov r1, #1e0
	store (r0), r1
_LBB0_1:                                ; %while.cond.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_1
	jmp _LBB0_2
_LBB0_2:                                ; %gpu_clear.exit
	mov r0, #a001c
	mov r1, #10
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_LBB0_3:                                ; %while.cond.i.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_3
	jmp _LBB0_4
_LBB0_4:                                ; %gpu_tri.exit.i
	mov r0, #a0000
	mov r1, #32
	store (r0), r1
	mov r0, #a0004
	mov r1, #1e
	store (r0), r1
	mov r0, #a0008
	mov r2, #c8
	store (r0), r2
	mov r0, #a000c
	store (r0), r1
	mov r0, #a0010
	store (r0), r2
	mov r0, #a0014
	mov r1, #64
	store (r0), r1
	mov r0, #a0018
	mov r1, #f800
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_5:                                ; %while.cond.i.i10.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_5
	jmp _LBB0_6
_LBB0_6:                                ; %gpu_rect.exit
	mov r0, #a0000
	mov r1, #32
	store (r0), r1
	mov r0, #a0004
	mov r2, #1e
	store (r0), r2
	mov r0, #a0008
	mov r2, #c8
	store (r0), r2
	mov r0, #a000c
	mov r2, #64
	store (r0), r2
	mov r0, #a0010
	store (r0), r1
	mov r0, #a0014
	store (r0), r2
	mov r0, #a0018
	mov r1, #f800
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_7:                                ; %while.cond.i.i.i1
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_7
	jmp _LBB0_8
_LBB0_8:                                ; %gpu_tri.exit.i4
	mov r0, #a0000
	mov r1, #dc
	store (r0), r1
	mov r0, #a0004
	mov r1, #1e
	store (r0), r1
	mov r0, #a0008
	mov r2, #1ae
	store (r0), r2
	mov r0, #a000c
	store (r0), r1
	mov r0, #a0010
	store (r0), r2
	mov r0, #a0014
	mov r1, #64
	store (r0), r1
	mov r0, #a0018
	mov r1, #7e0
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_9:                                ; %while.cond.i.i10.i5
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_9
	jmp _LBB0_10
_LBB0_10:                               ; %gpu_rect.exit8
	mov r0, #a0000
	mov r1, #dc
	store (r0), r1
	mov r0, #a0004
	mov r2, #1e
	store (r0), r2
	mov r0, #a0008
	mov r2, #1ae
	store (r0), r2
	mov r0, #a000c
	mov r2, #64
	store (r0), r2
	mov r0, #a0010
	store (r0), r1
	mov r0, #a0014
	store (r0), r2
	mov r0, #a0018
	mov r1, #7e0
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_11:                               ; %while.cond.i.i.i9
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_11
	jmp _LBB0_12
_LBB0_12:                               ; %gpu_tri.exit.i12
	mov r0, #a0000
	mov r1, #64
	store (r0), r1
	mov r0, #a0004
	mov r1, #8c
	store (r0), r1
	mov r0, #a0008
	mov r2, #17c
	store (r0), r2
	mov r0, #a000c
	store (r0), r1
	mov r0, #a0010
	store (r0), r2
	mov r0, #a0014
	mov r1, #e6
	store (r0), r1
	mov r0, #a0018
	mov r1, #ffe0
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_13:                               ; %while.cond.i.i10.i13
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_13
	jmp _LBB0_14
_LBB0_14:                               ; %gpu_rect.exit16
	mov r0, #a0000
	mov r1, #64
	store (r0), r1
	mov r0, #a0004
	mov r2, #8c
	store (r0), r2
	mov r0, #a0008
	mov r2, #17c
	store (r0), r2
	mov r0, #a000c
	mov r2, #e6
	store (r0), r2
	mov r0, #a0010
	store (r0), r1
	mov r0, #a0014
	store (r0), r2
	mov r0, #a0018
	mov r1, #ffe0
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_15:                               ; %while.cond.i.i.i17
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_15
	jmp _LBB0_16
_LBB0_16:                               ; %gpu_line.exit
	mov r0, #a0000
	mov r1, #a
	store (r0), r1
	mov r0, #a0004
	store (r0), r1
	mov r0, #a0008
	mov r1, #1d6
	store (r0), r1
	mov r0, #a000c
	mov r2, #104
	store (r0), r2
	mov r0, #a0010
	store (r0), r1
	mov r0, #a0014
	mov r1, #102
	store (r0), r1
	mov r0, #a0018
	mov r1, #ffff
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_17:                               ; %while.cond.i.i.i21
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_17
	jmp _LBB0_18
_LBB0_18:                               ; %gpu_line.exit25
	mov r0, #a0000
	mov r1, #1d6
	store (r0), r1
	mov r0, #a0004
	mov r1, #a
	store (r0), r1
	mov r0, #a0008
	store (r0), r1
	mov r0, #a000c
	mov r2, #104
	store (r0), r2
	mov r0, #a0010
	store (r0), r1
	mov r0, #a0014
	mov r1, #102
	store (r0), r1
	mov r0, #a0018
	mov r1, #7ff
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_19:                               ; %while.cond.i.i26
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_19
	jmp _LBB0_20
_LBB0_20:                               ; %gpu_swap.exit
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
	mov r0, #f0000
	mov r1, #1
	store (r0), r1
_LBB0_21:                               ; %for.cond
                                        ; =>This Inner Loop Header: Depth=1
	jmp _LBB0_21
                                        ; -- End function
