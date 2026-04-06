hal_putc:                               ; -- Begin function hal_putc
                                        ; @hal_putc
; %bb.0:                                ; %entry
	sub r14, #10
	mov r7, r14
	add r7, #c
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #8
	store (r7), r9                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #4
	store (r7), r15                         ; 4-byte Folded Spill
	mov r8, r2
	mov r9, r0
	mov r0, #1f
	cmp r0, r9
	jc _MAIN_LBB0_3
	jmp _MAIN_LBB0_1
_MAIN_LBB0_1:                                ; %entry
	mov r0, #f
	cmp r0, r1
	jc _MAIN_LBB0_3
	jmp _MAIN_LBB0_2
_MAIN_LBB0_2:                                ; %if.then
	mov r2, #7
	mov r0, r1
	mov r1, r2
	call __ashlsi3
	add r9, r9
	add r9, r9
	add r9, r0
	add r9, #10100
	store (r9), r8
_MAIN_LBB0_3:                                ; %if.end
	load r15, (r14+#4)                      ; 4-byte Folded Reload
	load r9, (r14+#8)                       ; 4-byte Folded Reload
	load r8, (r14+#c)                       ; 4-byte Folded Reload
	add r14, #10
	ret
                                        ; -- End function
hal_clear:                              ; -- Begin function hal_clear
                                        ; @hal_clear
; %bb.0:                                ; %entry
	sub r14, #4
	mov r0, #0
_MAIN_LBB1_1:                                ; %for.body
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, r0
	add r1, #10100
	mov r2, #20
	store (r1), r2
	add r0, #4
	cmp r0, #800
	jnz _MAIN_LBB1_1
	jmp _MAIN_LBB1_2
_MAIN_LBB1_2:                                ; %for.end
	add r14, #4
	ret
                                        ; -- End function
hal_swap:                               ; -- Begin function hal_swap
                                        ; @hal_swap
; %bb.0:                                ; %entry
	sub r14, #4
	mov r0, #e0000
	mov r1, #10100
_MAIN_LBB2_1:                                ; %for.body
                                        ; =>This Inner Loop Header: Depth=1
	load r2, (r1)
	store (r0), r2
	add r1, #4
	add r0, #1
	cmp r0, #e0200
	jnz _MAIN_LBB2_1
	jmp _MAIN_LBB2_2
_MAIN_LBB2_2:                                ; %for.end
	add r14, #4
	ret
                                        ; -- End function
main:                                   ; -- Begin function main
                                        ; @main
; %bb.0:                                ; %entry
	sub r14, #c
	mov r7, r14
	add r7, #8
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #4
	store (r7), r15                         ; 4-byte Folded Spill
_MAIN_LBB3_1:                                ; %while.cond.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _MAIN_LBB3_1
	jmp _MAIN_LBB3_2
_MAIN_LBB3_2:                                ; %gpu_wait.exit.i
	mov r0, #a001c
	mov r1, #0
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_MAIN_LBB3_3:                                ; %while.cond.i1.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _MAIN_LBB3_3
	jmp _MAIN_LBB3_4
_MAIN_LBB3_4:                                ; %gpu_wait.exit4.i
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
_MAIN_LBB3_5:                                ; %while.cond.i5.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _MAIN_LBB3_5
	jmp _MAIN_LBB3_6
_MAIN_LBB3_6:                                ; %gpu_wait.exit8.i
	mov r0, #a001c
	mov r1, #0
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_MAIN_LBB3_7:                                ; %while.cond.i9.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _MAIN_LBB3_7
	jmp _MAIN_LBB3_8
_MAIN_LBB3_8:                                ; %gpu_clear_black.exit
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
	mov r0, #c0000
	mov r1, #0
	store (r0), r1
	mov r0, #c0001
	store (r0), r1
	mov r0, #c0002
	mov r1, #20
	store (r0), r1
	mov r0, #c0003
	mov r1, #8010
	store (r0), r1
	mov r8, #10900
	mov r0, r8
	call game_init
	mov r0, r8
	call render_frame
	mov r0, #e0000
	mov r1, #10100
_MAIN_LBB3_9:                                ; %for.body.i
                                        ; =>This Inner Loop Header: Depth=1
	load r2, (r1)
	store (r0), r2
	add r1, #4
	add r0, #1
	cmp r0, #e0200
	jnz _MAIN_LBB3_9
	jmp _MAIN_LBB3_10
_MAIN_LBB3_10:                               ; %while.cond.i
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB3_12 Depth 2
	mov r0, #f0002
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jz _MAIN_LBB3_10
	jmp _MAIN_LBB3_11
_MAIN_LBB3_11:                               ; %uart_getchar.exit
                                        ;   in Loop: Header=BB3_10 Depth=1
	mov r0, #f0004
	load r1, (r0)
	and r1, #ff
	mov r8, #10900
	mov r0, r8
	call game_tick
	mov r0, r8
	call render_frame
	mov r0, #e0000
	mov r1, #10100
_MAIN_LBB3_12:                               ; %for.body.i4
                                        ;   Parent Loop BB3_10 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	load r2, (r1)
	store (r0), r2
	add r1, #4
	add r0, #1
	cmp r0, #e0200
	jz _MAIN_LBB3_10
	jmp _MAIN_LBB3_12
                                        ; -- End function
