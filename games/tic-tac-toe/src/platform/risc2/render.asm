render_frame:                           ; -- Begin function render_frame
                                        ; @render_frame
; %bb.0:                                ; %entry
	sub r14, #34
	mov r7, r14
	add r7, #30
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #2c
	store (r7), r9                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #28
	store (r7), r10                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #24
	store (r7), r11                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #20
	store (r7), r12                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #1c
	store (r7), r13                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #18
	store (r7), r15                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #10
	store (r7), r0                          ; 4-byte Folded Spill
	call hal_clear
	mov r9, #a
	mov r2, #54
	mov r8, @s_TITLE
	add r8, #4
_RENDER_LBB0_1:                                ; %while.body.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #1
	mov r0, r9
	call hal_putc
	load r2, (r8)
	add r8, #4
	add r9, #1
	cmp r9, #15
	jnz _RENDER_LBB0_1
	jmp _RENDER_LBB0_2
_RENDER_LBB0_2:                                ; %for.cond.preheader
	mov r8, #0
	load r0, (r14+#10)                      ; 4-byte Folded Reload
	mov r7, r14
	add r7, #c
	store (r7), r0                          ; 4-byte Folded Spill
_RENDER_LBB0_3:                                ; %for.body
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_4 Depth 2
                                        ;     Child Loop BB0_26 Depth 2
	mov r9, #0
	mov r10, #e
	mov r0, r8
	add r0, r0
	mov r7, r14
	add r7, #4
	store (r7), r0                          ; 4-byte Folded Spill
	add r0, #3
	mov r7, r14
	add r7, #14
	store (r7), r0                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #8
	store (r7), r8                          ; 4-byte Folded Spill
_RENDER_LBB0_4:                                ; %for.body3
                                        ;   Parent Loop BB0_3 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r13, #0
	load r0, (r14+#10)                      ; 4-byte Folded Reload
	load r0, (r0+#24)
	cmp r8, r0
	jnz _RENDER_LBB0_9
	jmp _RENDER_LBB0_5
_RENDER_LBB0_5:                                ; %land.lhs.true
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r13, #0
	load r0, (r14+#10)                      ; 4-byte Folded Reload
	load r0, (r0+#28)
	cmp r9, r0
	jnz _RENDER_LBB0_9
	jmp _RENDER_LBB0_6
_RENDER_LBB0_6:                                ; %land.rhs
                                        ;   in Loop: Header=BB0_4 Depth=2
	load r0, (r14+#10)                      ; 4-byte Folded Reload
	load r2, (r0+#2c)
	mov r0, #0
	mov r1, #1
	cmp r2, r0
	jz _RENDER_LBB0_8
; %bb.7:                                ; %land.rhs
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r13, r0
	jmp _RENDER_LBB0_9
_RENDER_LBB0_8:                                ; %land.rhs
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r13, r1
_RENDER_LBB0_9:                                ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	and r13, #1
	mov r8, #0
	mov r12, #20
	mov r0, #5b
	cmp r13, r8
	jnz _RENDER_LBB0_11
; %bb.10:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, r12
	jmp _RENDER_LBB0_12
_RENDER_LBB0_11:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, r0
_RENDER_LBB0_12:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r0, r10
	imm #fff
	add r0, #ffffd
	load r1, (r14+#c)                       ; 4-byte Folded Reload
	add r1, r10
	imm #fff
	add r1, #ffff2
	load r11, (r1)
	load r1, (r14+#14)                      ; 4-byte Folded Reload
	call hal_putc
	mov r1, #1
	mov r0, #58
	cmp r11, r1
	jz _RENDER_LBB0_14
; %bb.13:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r0, r12
	jmp _RENDER_LBB0_15
_RENDER_LBB0_14:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r0, r0
_RENDER_LBB0_15:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, #2
	mov r1, #4f
	cmp r11, r2
	jz _RENDER_LBB0_17
; %bb.16:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, r0
	jmp _RENDER_LBB0_18
_RENDER_LBB0_17:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, r1
_RENDER_LBB0_18:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r0, r10
	imm #fff
	add r0, #ffffe
	load r1, (r14+#14)                      ; 4-byte Folded Reload
	call hal_putc
	mov r0, #5d
	cmp r13, r8
	jnz _RENDER_LBB0_20
; %bb.19:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, r12
	load r8, (r14+#8)                       ; 4-byte Folded Reload
	jmp _RENDER_LBB0_21
_RENDER_LBB0_20:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, r0
	load r8, (r14+#8)                       ; 4-byte Folded Reload
_RENDER_LBB0_21:                               ; %land.end
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r0, r10
	imm #fff
	add r0, #fffff
	load r1, (r14+#14)                      ; 4-byte Folded Reload
	call hal_putc
	cmp r10, #16
	jz _RENDER_LBB0_23
	jmp _RENDER_LBB0_22
_RENDER_LBB0_22:                               ; %if.then24
                                        ;   in Loop: Header=BB0_4 Depth=2
	mov r2, #7c
	mov r0, r10
	load r1, (r14+#14)                      ; 4-byte Folded Reload
	call hal_putc
_RENDER_LBB0_23:                               ; %if.end26
                                        ;   in Loop: Header=BB0_4 Depth=2
	add r9, #1
	add r10, #4
	cmp r10, #1a
	jnz _RENDER_LBB0_4
	jmp _RENDER_LBB0_24
_RENDER_LBB0_24:                               ; %for.end
                                        ;   in Loop: Header=BB0_3 Depth=1
	cmp r8, #2
	jz _RENDER_LBB0_28
	jmp _RENDER_LBB0_25
_RENDER_LBB0_25:                               ; %if.then28
                                        ;   in Loop: Header=BB0_3 Depth=1
	mov r10, #b
	load r9, (r14+#4)                       ; 4-byte Folded Reload
	add r9, #4
_RENDER_LBB0_26:                               ; %for.body33
                                        ;   Parent Loop BB0_3 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r2, #2d
	mov r0, r10
	mov r1, r9
	call hal_putc
	add r10, #1
	cmp r10, #15
	jnz _RENDER_LBB0_26
	jmp _RENDER_LBB0_27
_RENDER_LBB0_27:                               ; %for.end36
                                        ;   in Loop: Header=BB0_3 Depth=1
	mov r0, #e
	mov r10, #2b
	mov r1, r9
	mov r2, r10
	call hal_putc
	mov r0, #12
	mov r1, r9
	mov r2, r10
	call hal_putc
_RENDER_LBB0_28:                               ; %if.end39
                                        ;   in Loop: Header=BB0_3 Depth=1
	load r0, (r14+#c)                       ; 4-byte Folded Reload
	add r0, #c
	mov r7, r14
	add r7, #c
	store (r7), r0                          ; 4-byte Folded Spill
	add r8, #1
	cmp r8, #3
	jnz _RENDER_LBB0_3
	jmp _RENDER_LBB0_29
_RENDER_LBB0_29:                               ; %for.end42
	load r0, (r14+#10)                      ; 4-byte Folded Reload
	load r0, (r0+#2c)
	cmp r0, #0
	jz _RENDER_LBB0_34
	jmp _RENDER_LBB0_30
_RENDER_LBB0_30:                               ; %for.end42
	cmp r0, #1
	jz _RENDER_LBB0_33
	jmp _RENDER_LBB0_31
_RENDER_LBB0_31:                               ; %for.end42
	cmp r0, #2
	jnz _RENDER_LBB0_35
	jmp _RENDER_LBB0_32
_RENDER_LBB0_32:                               ; %while.body.i129.preheader
	mov r8, #7
	mov r2, #59
	mov r9, @s_LOSE
	add r9, #4
	jmp _RENDER_LBB0_38
_RENDER_LBB0_38:                               ; %while.body.i129
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #9
	mov r0, r8
	call hal_putc
	load r2, (r9)
	add r9, #4
	add r8, #1
	cmp r8, #18
	jz _RENDER_LBB0_40
	jmp _RENDER_LBB0_38
_RENDER_LBB0_33:                               ; %while.body.i119.preheader
	mov r8, #7
	mov r2, #59
	mov r9, @s_WIN
	add r9, #4
	jmp _RENDER_LBB0_37
_RENDER_LBB0_37:                               ; %while.body.i119
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #9
	mov r0, r8
	call hal_putc
	load r2, (r9)
	add r9, #4
	add r8, #1
	cmp r8, #19
	jz _RENDER_LBB0_40
	jmp _RENDER_LBB0_37
_RENDER_LBB0_34:                               ; %while.body.i109.preheader
	mov r8, #9
	mov r2, #59
	mov r9, @s_TURN
	add r9, #4
	jmp _RENDER_LBB0_36
_RENDER_LBB0_36:                               ; %while.body.i109
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #9
	mov r0, r8
	call hal_putc
	load r2, (r9)
	add r9, #4
	add r8, #1
	cmp r8, #16
	jz _RENDER_LBB0_40
	jmp _RENDER_LBB0_36
_RENDER_LBB0_35:                               ; %while.body.i139.preheader
	mov r8, #8
	mov r2, #44
	mov r9, @s_DRAW
	add r9, #4
	jmp _RENDER_LBB0_39
_RENDER_LBB0_39:                               ; %while.body.i139
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #9
	mov r0, r8
	call hal_putc
	load r2, (r9)
	add r9, #4
	add r8, #1
	cmp r8, #17
	jnz _RENDER_LBB0_39
	jmp _RENDER_LBB0_40
_RENDER_LBB0_40:                               ; %while.body.i149.preheader
	mov r8, #6
	mov r2, #57
	mov r9, @s_CTRL
	add r9, #4
_RENDER_LBB0_41:                               ; %while.body.i149
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #b
	mov r0, r8
	call hal_putc
	load r2, (r9)
	add r9, #4
	add r8, #1
	cmp r8, #19
	jnz _RENDER_LBB0_41
	jmp _RENDER_LBB0_42
_RENDER_LBB0_42:                               ; %put_str.exit158
	load r15, (r14+#18)                     ; 4-byte Folded Reload
	load r13, (r14+#1c)                     ; 4-byte Folded Reload
	load r12, (r14+#20)                     ; 4-byte Folded Reload
	load r11, (r14+#24)                     ; 4-byte Folded Reload
	load r10, (r14+#28)                     ; 4-byte Folded Reload
	load r9, (r14+#2c)                      ; 4-byte Folded Reload
	load r8, (r14+#30)                      ; 4-byte Folded Reload
	add r14, #34
	ret
                                        ; -- End function
s_TITLE:
	.dd 84
	.dd 73
	.dd 67
	.dd 45
	.dd 84
	.dd 65
	.dd 67
	.dd 45
	.dd 84
	.dd 79
	.dd 69
	.dd 0
s_TURN:
	.dd 89
	.dd 79
	.dd 85
	.dd 82
	.dd 32
	.dd 84
	.dd 85
	.dd 82
	.dd 78
	.dd 32
	.dd 40
	.dd 88
	.dd 41
	.dd 0
s_WIN:
	.dd 89
	.dd 79
	.dd 85
	.dd 32
	.dd 87
	.dd 73
	.dd 78
	.dd 33
	.dd 32
	.dd 83
	.dd 80
	.dd 65
	.dd 67
	.dd 69
	.dd 61
	.dd 78
	.dd 69
	.dd 87
	.dd 0
s_LOSE:
	.dd 89
	.dd 79
	.dd 85
	.dd 32
	.dd 76
	.dd 79
	.dd 83
	.dd 69
	.dd 33
	.dd 32
	.dd 83
	.dd 80
	.dd 67
	.dd 61
	.dd 78
	.dd 69
	.dd 87
	.dd 0
s_DRAW:
	.dd 68
	.dd 82
	.dd 65
	.dd 87
	.dd 33
	.dd 32
	.dd 83
	.dd 80
	.dd 65
	.dd 67
	.dd 69
	.dd 61
	.dd 78
	.dd 69
	.dd 87
	.dd 0
s_CTRL:
	.dd 87
	.dd 65
	.dd 83
	.dd 68
	.dd 61
	.dd 77
	.dd 79
	.dd 86
	.dd 69
	.dd 32
	.dd 83
	.dd 80
	.dd 67
	.dd 61
	.dd 80
	.dd 76
	.dd 65
	.dd 67
	.dd 69
	.dd 0
