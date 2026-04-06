game_init:                              ; -- Begin function game_init
                                        ; @game_init
; %bb.0:                                ; %entry
	sub r14, #4
	mov r1, #0
_GAME_LBB0_1:                                ; %for.body
                                        ; =>This Inner Loop Header: Depth=1
	mov r2, r0
	add r2, r1
	mov r3, #0
	store (r2), r3
	add r1, #4
	cmp r1, #24
	jnz _GAME_LBB0_1
	jmp _GAME_LBB0_2
_GAME_LBB0_2:                                ; %for.end
	mov r1, r0
	add r1, #2c
	mov r2, #0
	store (r1), r2
	mov r1, r0
	add r1, #28
	mov r2, #1
	store (r1), r2
	add r0, #24
	store (r0), r2
	add r14, #4
	ret
                                        ; -- End function
game_tick:                              ; -- Begin function game_tick
                                        ; @game_tick
; %bb.0:                                ; %entry
	sub r14, #c
	mov r7, r14
	add r7, #8
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #4
	store (r7), r15                         ; 4-byte Folded Spill
	load r2, (r0+#2c)
	cmp r2, #0
	jz _GAME_LBB1_6
	jmp _GAME_LBB1_1
_GAME_LBB1_1:                                ; %if.then
	cmp r1, #20
	jz _GAME_LBB1_3
	jmp _GAME_LBB1_2
_GAME_LBB1_2:                                ; %if.then
	cmp r1, #d
	jnz _GAME_LBB1_31
	jmp _GAME_LBB1_3
_GAME_LBB1_3:                                ; %for.body.i.preheader
	mov r1, #0
_GAME_LBB1_4:                                ; %for.body.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r2, r0
	add r2, r1
	mov r3, #0
	store (r2), r3
	add r1, #4
	cmp r1, #24
	jnz _GAME_LBB1_4
	jmp _GAME_LBB1_5
_GAME_LBB1_5:                                ; %game_init.exit
	mov r1, r0
	add r1, #2c
	mov r2, #0
	store (r1), r2
	mov r1, r0
	add r1, #28
	mov r2, #1
	store (r1), r2
	add r0, #24
	store (r0), r2
	jmp _GAME_LBB1_31
_GAME_LBB1_6:                                ; %if.end4
	mov r2, #63
	cmp r2, r1
	jlt _GAME_LBB1_10
	jmp _GAME_LBB1_7
_GAME_LBB1_7:                                ; %if.end4
	cmp r1, #d
	jz _GAME_LBB1_21
	jmp _GAME_LBB1_8
_GAME_LBB1_8:                                ; %if.end4
	cmp r1, #20
	jz _GAME_LBB1_21
	jmp _GAME_LBB1_9
_GAME_LBB1_9:                                ; %if.end4
	cmp r1, #61
	jz _GAME_LBB1_17
	jmp _GAME_LBB1_31
_GAME_LBB1_17:                               ; %sw.bb15
	load r1, (r0+#28)
	cmp r1, #1
	jlt _GAME_LBB1_31
	jmp _GAME_LBB1_18
_GAME_LBB1_18:                               ; %if.then17
	add r0, #28
	imm #fff
	add r1, #fffff
	store (r0), r1
	jmp _GAME_LBB1_31
_GAME_LBB1_10:                               ; %if.end4
	cmp r1, #64
	jz _GAME_LBB1_19
	jmp _GAME_LBB1_11
_GAME_LBB1_11:                               ; %if.end4
	cmp r1, #73
	jz _GAME_LBB1_15
	jmp _GAME_LBB1_12
_GAME_LBB1_12:                               ; %if.end4
	cmp r1, #77
	jnz _GAME_LBB1_31
	jmp _GAME_LBB1_13
_GAME_LBB1_13:                               ; %sw.bb
	load r1, (r0+#24)
	cmp r1, #1
	jlt _GAME_LBB1_31
	jmp _GAME_LBB1_14
_GAME_LBB1_14:                               ; %if.then6
	add r0, #24
	imm #fff
	add r1, #fffff
	store (r0), r1
	jmp _GAME_LBB1_31
_GAME_LBB1_21:                               ; %sw.bb28
	load r2, (r0+#24)
	mov r1, #c
	mov r8, r0
	mov r0, r2
	call __mulsi3
	mov r1, r8
	add r0, r1
	load r1, (r1+#28)
	add r1, r1
	add r1, r1
	add r1, r0
	load r0, (r1)
	cmp r0, #0
	jnz _GAME_LBB1_31
	jmp _GAME_LBB1_22
_GAME_LBB1_22:                               ; %if.then33
	mov r0, #1
	store (r1), r0
	mov r0, r8
	call check_winner
	mov r1, r0
	mov r2, r1
	imm #fff
	add r2, #fffff
	cmp r2, #2
	jc _GAME_LBB1_28
	jmp _GAME_LBB1_23
_GAME_LBB1_28:                               ; %update_state.exit.sink.split
	mov r2, r8
	add r2, #2c
	store (r2), r1
_GAME_LBB1_29:                               ; %update_state.exit
	load r1, (r8+#2c)
	cmp r1, #0
	jnz _GAME_LBB1_31
	jmp _GAME_LBB1_30
_GAME_LBB1_30:                               ; %if.then41
	mov r0, r8
	call ai_move
_GAME_LBB1_31:                               ; %sw.epilog
	load r15, (r14+#4)                      ; 4-byte Folded Reload
	load r8, (r14+#8)                       ; 4-byte Folded Reload
	add r14, #c
	ret
_GAME_LBB1_19:                               ; %sw.bb21
	load r1, (r0+#28)
	mov r2, #1
	cmp r2, r1
	jlt _GAME_LBB1_31
	jmp _GAME_LBB1_20
_GAME_LBB1_20:                               ; %if.then24
	add r0, #28
	add r1, #1
	store (r0), r1
	jmp _GAME_LBB1_31
_GAME_LBB1_15:                               ; %sw.bb9
	load r1, (r0+#24)
	mov r2, #1
	cmp r2, r1
	jlt _GAME_LBB1_31
	jmp _GAME_LBB1_16
_GAME_LBB1_16:                               ; %if.then12
	add r0, #24
	add r1, #1
	store (r0), r1
	jmp _GAME_LBB1_31
_GAME_LBB1_23:                               ; %for.cond1.preheader.i.i.preheader
	mov r2, #0
	mov r3, r8
_GAME_LBB1_24:                               ; %for.cond1.preheader.i.i
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB1_26 Depth 2
	mov r1, #0
	jmp _GAME_LBB1_26
_GAME_LBB1_26:                               ; %for.body3.i.i
                                        ;   Parent Loop BB1_24 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r4, r3
	add r4, r1
	load r4, (r4)
	cmp r4, #0
	jz _GAME_LBB1_29
	jmp _GAME_LBB1_25
_GAME_LBB1_25:                               ; %for.cond1.i.i
                                        ;   in Loop: Header=BB1_26 Depth=2
	add r1, #4
	cmp r1, #c
	jz _GAME_LBB1_27
	jmp _GAME_LBB1_26
_GAME_LBB1_27:                               ; %for.inc6.i.i
                                        ;   in Loop: Header=BB1_24 Depth=1
	mov r1, #3
	add r3, #c
	add r2, #1
	cmp r2, #3
	jnz _GAME_LBB1_24
	jmp _GAME_LBB1_28
                                        ; -- End function
ai_move:                                ; -- Begin function ai_move
                                        ; @ai_move
; %bb.0:                                ; %entry
	sub r14, #2c
	mov r7, r14
	add r7, #28
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #24
	store (r7), r9                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #20
	store (r7), r10                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #1c
	store (r7), r11                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #18
	store (r7), r12                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #14
	store (r7), r13                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #10
	store (r7), r15                         ; 4-byte Folded Spill
	mov r12, r0
	imm #fff
	mov r9, #fffff
	mov r1, #0
	mov r7, r14
	add r7, #8
	store (r7), r1                          ; 4-byte Folded Spill
	imm #fff
	mov r13, #fff9c
	mov r7, r14
	add r7, #c
	store (r7), r12                         ; 4-byte Folded Spill
	mov r11, r9
_GAME_LBB2_1:                                ; %for.cond1.preheader
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB2_2 Depth 2
	mov r8, #0
	mov r7, r14
	add r7, #4
	store (r7), r12                         ; 4-byte Folded Spill
_GAME_LBB2_2:                                ; %for.body3
                                        ;   Parent Loop BB2_1 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	load r0, (r12)
	cmp r0, #0
	jnz _GAME_LBB2_12
	jmp _GAME_LBB2_3
_GAME_LBB2_3:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	mov r0, #2
	store (r12), r0
	mov r10, #0
	load r0, (r14+#c)                       ; 4-byte Folded Reload
	mov r1, r10
	call minimax
	store (r12), r10
	cmp r13, r0
	jlt _GAME_LBB2_5
; %bb.4:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	mov r11, r11
	jmp _GAME_LBB2_6
_GAME_LBB2_5:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	mov r11, r8
_GAME_LBB2_6:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	cmp r13, r0
	jlt _GAME_LBB2_8
; %bb.7:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	mov r9, r9
	jmp _GAME_LBB2_9
_GAME_LBB2_8:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	load r1, (r14+#8)                       ; 4-byte Folded Reload
	mov r9, r1
_GAME_LBB2_9:                                ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	cmp r13, r0
	jlt _GAME_LBB2_11
; %bb.10:                               ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	mov r13, r13
	jmp _GAME_LBB2_12
_GAME_LBB2_11:                               ; %if.then
                                        ;   in Loop: Header=BB2_2 Depth=2
	mov r13, r0
_GAME_LBB2_12:                               ; %for.inc
                                        ;   in Loop: Header=BB2_2 Depth=2
	add r12, #4
	add r8, #1
	cmp r8, #3
	jnz _GAME_LBB2_2
	jmp _GAME_LBB2_13
_GAME_LBB2_13:                               ; %for.inc15
                                        ;   in Loop: Header=BB2_1 Depth=1
	load r12, (r14+#4)                      ; 4-byte Folded Reload
	add r12, #c
	load r0, (r14+#8)                       ; 4-byte Folded Reload
	add r0, #1
	mov r7, r14
	add r7, #8
	store (r7), r0                          ; 4-byte Folded Spill
	cmp r0, #3
	jnz _GAME_LBB2_1
	jmp _GAME_LBB2_14
_GAME_LBB2_14:                               ; %for.end17
	cmp r9, #0
	jlt _GAME_LBB2_22
	jmp _GAME_LBB2_15
_GAME_LBB2_15:                               ; %if.then19
	mov r1, #c
	mov r0, r9
	call __mulsi3
	load r1, (r14+#c)                       ; 4-byte Folded Reload
	add r0, r1
	add r11, r11
	add r11, r11
	add r11, r0
	mov r0, #2
	store (r11), r0
	mov r0, r1
	call check_winner
	mov r1, r0
	imm #fff
	add r1, #fffff
	cmp r1, #2
	jc _GAME_LBB2_21
	jmp _GAME_LBB2_16
_GAME_LBB2_21:                               ; %if.end23.sink.split
	load r1, (r14+#c)                       ; 4-byte Folded Reload
	add r1, #2c
	store (r1), r0
_GAME_LBB2_22:                               ; %if.end23
	load r15, (r14+#10)                     ; 4-byte Folded Reload
	load r13, (r14+#14)                     ; 4-byte Folded Reload
	load r12, (r14+#18)                     ; 4-byte Folded Reload
	load r11, (r14+#1c)                     ; 4-byte Folded Reload
	load r10, (r14+#20)                     ; 4-byte Folded Reload
	load r9, (r14+#24)                      ; 4-byte Folded Reload
	load r8, (r14+#28)                      ; 4-byte Folded Reload
	add r14, #2c
	ret
_GAME_LBB2_16:                               ; %for.cond1.preheader.i.i.preheader
	mov r1, #0
	load r2, (r14+#c)                       ; 4-byte Folded Reload
_GAME_LBB2_17:                               ; %for.cond1.preheader.i.i
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB2_19 Depth 2
	mov r0, #0
	jmp _GAME_LBB2_19
_GAME_LBB2_19:                               ; %for.body3.i.i
                                        ;   Parent Loop BB2_17 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r3, r2
	add r3, r0
	load r3, (r3)
	cmp r3, #0
	jz _GAME_LBB2_22
	jmp _GAME_LBB2_18
_GAME_LBB2_18:                               ; %for.cond1.i.i
                                        ;   in Loop: Header=BB2_19 Depth=2
	add r0, #4
	cmp r0, #c
	jz _GAME_LBB2_20
	jmp _GAME_LBB2_19
_GAME_LBB2_20:                               ; %for.inc6.i.i
                                        ;   in Loop: Header=BB2_17 Depth=1
	mov r0, #3
	add r2, #c
	add r1, #1
	cmp r1, #3
	jnz _GAME_LBB2_17
	jmp _GAME_LBB2_21
                                        ; -- End function
check_winner:                           ; -- Begin function check_winner
                                        ; @check_winner
; %bb.0:                                ; %entry
	sub r14, #4
	mov r2, #0
	jmp _GAME_LBB3_3
_GAME_LBB3_3:                                ; %for.body
                                        ; =>This Inner Loop Header: Depth=1
	mov r3, r0
	add r3, r2
	load r1, (r3)
	cmp r1, #0
	jz _GAME_LBB3_6
	jmp _GAME_LBB3_4
_GAME_LBB3_4:                                ; %land.lhs.true.i
                                        ;   in Loop: Header=BB3_3 Depth=1
	load r4, (r3+#4)
	cmp r1, r4
	jnz _GAME_LBB3_6
	jmp _GAME_LBB3_5
_GAME_LBB3_5:                                ; %land.lhs.true6.i
                                        ;   in Loop: Header=BB3_3 Depth=1
	load r3, (r3+#8)
	cmp r1, r3
	jz _GAME_LBB3_7
	jmp _GAME_LBB3_6
_GAME_LBB3_6:                                ; %if.end.i
                                        ;   in Loop: Header=BB3_3 Depth=1
	mov r1, #0
_GAME_LBB3_7:                                ; %check_line.exit
                                        ;   in Loop: Header=BB3_3 Depth=1
	cmp r1, #0
	jz _GAME_LBB3_1
	jmp _GAME_LBB3_23
_GAME_LBB3_1:                                ; %for.cond
                                        ;   in Loop: Header=BB3_3 Depth=1
	add r2, #c
	cmp r2, #24
	jnz _GAME_LBB3_3
	jmp _GAME_LBB3_2
_GAME_LBB3_2:                                ; %for.cond1.preheader
	mov r2, #0
	jmp _GAME_LBB3_9
_GAME_LBB3_9:                                ; %for.body3
                                        ; =>This Inner Loop Header: Depth=1
	mov r3, r0
	add r3, r2
	load r1, (r3)
	cmp r1, #0
	jz _GAME_LBB3_12
	jmp _GAME_LBB3_10
_GAME_LBB3_10:                               ; %land.lhs.true.i41
                                        ;   in Loop: Header=BB3_9 Depth=1
	load r4, (r3+#c)
	cmp r1, r4
	jnz _GAME_LBB3_12
	jmp _GAME_LBB3_11
_GAME_LBB3_11:                               ; %land.lhs.true6.i47
                                        ;   in Loop: Header=BB3_9 Depth=1
	load r3, (r3+#18)
	cmp r1, r3
	jz _GAME_LBB3_13
	jmp _GAME_LBB3_12
_GAME_LBB3_12:                               ; %if.end.i45
                                        ;   in Loop: Header=BB3_9 Depth=1
	mov r1, #0
_GAME_LBB3_13:                               ; %check_line.exit51
                                        ;   in Loop: Header=BB3_9 Depth=1
	cmp r1, #0
	jz _GAME_LBB3_8
	jmp _GAME_LBB3_23
_GAME_LBB3_8:                                ; %for.cond1
                                        ;   in Loop: Header=BB3_9 Depth=1
	add r2, #4
	cmp r2, #c
	jz _GAME_LBB3_14
	jmp _GAME_LBB3_9
_GAME_LBB3_14:                               ; %for.end10
	load r1, (r0)
	cmp r1, #0
	jz _GAME_LBB3_17
	jmp _GAME_LBB3_15
_GAME_LBB3_15:                               ; %land.lhs.true.i55
	load r2, (r0+#10)
	cmp r1, r2
	jnz _GAME_LBB3_17
	jmp _GAME_LBB3_16
_GAME_LBB3_16:                               ; %land.lhs.true6.i61
	load r2, (r0+#20)
	cmp r1, r2
	jz _GAME_LBB3_18
	jmp _GAME_LBB3_17
_GAME_LBB3_17:                               ; %if.end.i59
	mov r1, #0
_GAME_LBB3_18:                               ; %check_line.exit65
	cmp r1, #0
	jnz _GAME_LBB3_23
	jmp _GAME_LBB3_19
_GAME_LBB3_19:                               ; %if.end14
	load r1, (r0+#8)
	cmp r1, #0
	jz _GAME_LBB3_22
	jmp _GAME_LBB3_20
_GAME_LBB3_20:                               ; %land.lhs.true.i69
	load r2, (r0+#10)
	cmp r1, r2
	jnz _GAME_LBB3_22
	jmp _GAME_LBB3_21
_GAME_LBB3_21:                               ; %land.lhs.true6.i75
	load r0, (r0+#18)
	cmp r1, r0
	jz _GAME_LBB3_23
	jmp _GAME_LBB3_22
_GAME_LBB3_22:                               ; %if.end.i73
	mov r1, #0
_GAME_LBB3_23:                               ; %cleanup
	mov r0, r1
	add r14, #4
	ret
                                        ; -- End function
minimax:                                ; -- Begin function minimax
                                        ; @minimax
; %bb.0:                                ; %entry
	sub r14, #24
	mov r7, r14
	add r7, #20
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #1c
	store (r7), r9                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #18
	store (r7), r10                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #14
	store (r7), r11                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #10
	store (r7), r12                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #c
	store (r7), r13                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #8
	store (r7), r15                         ; 4-byte Folded Spill
	mov r10, r1
	mov r7, r14
	add r7, #4
	store (r7), r0                          ; 4-byte Folded Spill
	call check_winner
	mov r9, #a
	cmp r0, #1
	jz _GAME_LBB4_3
	jmp _GAME_LBB4_1
_GAME_LBB4_1:                                ; %entry
	cmp r0, #2
	jz _GAME_LBB4_25
	jmp _GAME_LBB4_2
_GAME_LBB4_2:                                ; %for.cond1.preheader.i.preheader
	mov r0, #0
	load r1, (r14+#4)                       ; 4-byte Folded Reload
	jmp _GAME_LBB4_4
_GAME_LBB4_4:                                ; %for.cond1.preheader.i
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB4_6 Depth 2
	mov r2, #0
	jmp _GAME_LBB4_6
_GAME_LBB4_6:                                ; %for.body3.i
                                        ;   Parent Loop BB4_4 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r3, r1
	add r3, r2
	load r3, (r3)
	cmp r3, #0
	jz _GAME_LBB4_8
	jmp _GAME_LBB4_5
_GAME_LBB4_5:                                ; %for.cond1.i
                                        ;   in Loop: Header=BB4_6 Depth=2
	add r2, #4
	cmp r2, #c
	jz _GAME_LBB4_7
	jmp _GAME_LBB4_6
_GAME_LBB4_7:                                ; %for.inc6.i
                                        ;   in Loop: Header=BB4_4 Depth=1
	mov r9, #0
	add r1, #c
	add r0, #1
	cmp r0, #3
	jz _GAME_LBB4_25
	jmp _GAME_LBB4_4
_GAME_LBB4_3:                                ; %if.then2
	imm #fff
	mov r9, #ffff6
	jmp _GAME_LBB4_25
_GAME_LBB4_8:                                ; %if.end6
	cmp r10, #0
	jz _GAME_LBB4_10
	jmp _GAME_LBB4_9
_GAME_LBB4_9:                                ; %for.cond10.preheader.preheader
	imm #fff
	mov r9, #fff9c
	mov r11, #0
	load r8, (r14+#4)                       ; 4-byte Folded Reload
	jmp _GAME_LBB4_11
_GAME_LBB4_11:                               ; %for.cond10.preheader
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB4_12 Depth 2
	mov r13, #0
_GAME_LBB4_12:                               ; %for.body12
                                        ;   Parent Loop BB4_11 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r12, r8
	add r12, r13
	load r0, (r12)
	cmp r0, #0
	jnz _GAME_LBB4_16
	jmp _GAME_LBB4_13
_GAME_LBB4_13:                               ; %if.then15
                                        ;   in Loop: Header=BB4_12 Depth=2
	mov r0, #2
	store (r12), r0
	mov r10, #0
	load r0, (r14+#4)                       ; 4-byte Folded Reload
	mov r1, r10
	call minimax
	store (r12), r10
	cmp r9, r0
	jlt _GAME_LBB4_15
; %bb.14:                               ; %if.then15
                                        ;   in Loop: Header=BB4_12 Depth=2
	mov r9, r9
	jmp _GAME_LBB4_16
_GAME_LBB4_15:                               ; %if.then15
                                        ;   in Loop: Header=BB4_12 Depth=2
	mov r9, r0
_GAME_LBB4_16:                               ; %for.inc
                                        ;   in Loop: Header=BB4_12 Depth=2
	add r13, #4
	cmp r13, #c
	jnz _GAME_LBB4_12
	jmp _GAME_LBB4_17
_GAME_LBB4_17:                               ; %for.inc27
                                        ;   in Loop: Header=BB4_11 Depth=1
	add r8, #c
	add r11, #1
	cmp r11, #3
	jz _GAME_LBB4_25
	jmp _GAME_LBB4_11
_GAME_LBB4_10:                               ; %for.cond33.preheader.preheader
	mov r9, #64
	mov r10, #0
	load r11, (r14+#4)                      ; 4-byte Folded Reload
	jmp _GAME_LBB4_18
_GAME_LBB4_18:                               ; %for.cond33.preheader
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB4_19 Depth 2
	mov r12, #0
_GAME_LBB4_19:                               ; %for.body35
                                        ;   Parent Loop BB4_18 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r8, r11
	add r8, r12
	load r0, (r8)
	cmp r0, #0
	jnz _GAME_LBB4_23
	jmp _GAME_LBB4_20
_GAME_LBB4_20:                               ; %if.then40
                                        ;   in Loop: Header=BB4_19 Depth=2
	mov r1, #1
	store (r8), r1
	load r0, (r14+#4)                       ; 4-byte Folded Reload
	call minimax
	mov r1, #0
	store (r8), r1
	cmp r0, r9
	jlt _GAME_LBB4_22
; %bb.21:                               ; %if.then40
                                        ;   in Loop: Header=BB4_19 Depth=2
	mov r9, r9
	jmp _GAME_LBB4_23
_GAME_LBB4_22:                               ; %if.then40
                                        ;   in Loop: Header=BB4_19 Depth=2
	mov r9, r0
_GAME_LBB4_23:                               ; %for.inc53
                                        ;   in Loop: Header=BB4_19 Depth=2
	add r12, #4
	cmp r12, #c
	jnz _GAME_LBB4_19
	jmp _GAME_LBB4_24
_GAME_LBB4_24:                               ; %for.inc56
                                        ;   in Loop: Header=BB4_18 Depth=1
	add r11, #c
	add r10, #1
	cmp r10, #3
	jnz _GAME_LBB4_18
	jmp _GAME_LBB4_25
_GAME_LBB4_25:                               ; %cleanup
	mov r0, r9
	load r15, (r14+#8)                      ; 4-byte Folded Reload
	load r13, (r14+#c)                      ; 4-byte Folded Reload
	load r12, (r14+#10)                     ; 4-byte Folded Reload
	load r11, (r14+#14)                     ; 4-byte Folded Reload
	load r10, (r14+#18)                     ; 4-byte Folded Reload
	load r9, (r14+#1c)                      ; 4-byte Folded Reload
	load r8, (r14+#20)                      ; 4-byte Folded Reload
	add r14, #24
	ret
                                        ; -- End function
