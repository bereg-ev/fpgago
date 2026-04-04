main:                                   ; -- Begin function main
                                        ; @main
; %bb.0:                                ; %entry
	sub r14, #44
	mov r7, r14
	add r7, #40
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #3c
	store (r7), r9                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #38
	store (r7), r10                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #34
	store (r7), r11                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #30
	store (r7), r12                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #2c
	store (r7), r13                         ; 4-byte Folded Spill
	mov r7, r14
	add r7, #28
	store (r7), r15                         ; 4-byte Folded Spill
_LBB0_1:                                ; %while.cond.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_1
	jmp _LBB0_2
_LBB0_2:                                ; %uart_putc.exit
	mov r0, #f0003
	mov r1, #50
	store (r0), r1
_LBB0_3:                                ; %while.cond.i372
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_3
	jmp _LBB0_4
_LBB0_4:                                ; %uart_putc.exit375
	mov r0, #f0003
	mov r1, #31
	store (r0), r1
_LBB0_5:                                ; %while.cond.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_5
	jmp _LBB0_6
_LBB0_6:                                ; %uart_putc.exit.i
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_7:                                ; %while.cond.i1.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_7
	jmp _LBB0_8
_LBB0_8:                                ; %uart_crlf.exit
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_9:                                ; %while.cond.i.i376
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_9
	jmp _LBB0_10
_LBB0_10:                               ; %gpu_clear.exit
	mov r0, #a001c
	mov r1, #8
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_LBB0_11:                               ; %while.cond.i.i379
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_11
	jmp _LBB0_12
_LBB0_12:                               ; %gpu_tri.exit
	mov r0, #a0000
	mov r1, #c8
	store (r0), r1
	mov r0, #a0004
	mov r2, #32
	store (r0), r2
	mov r0, #a0008
	mov r2, #12c
	store (r0), r2
	mov r0, #a000c
	store (r0), r1
	mov r0, #a0010
	mov r2, #64
	store (r0), r2
	mov r0, #a0014
	store (r0), r1
	mov r0, #a0018
	mov r1, #7e0
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_13:                               ; %while.cond.i.i382
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_13
	jmp _LBB0_14
_LBB0_14:                               ; %gpu_swap.exit
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
_LBB0_15:                               ; %while.cond.i.i385
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_15
	jmp _LBB0_16
_LBB0_16:                               ; %uart_putc.exit.i388
	mov r0, #f0003
	mov r1, #3e
	store (r0), r1
_LBB0_17:                               ; %while.cond.i1.i389
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jz _LBB0_17
	jmp _LBB0_18
_LBB0_18:                               ; %uart_getc.exit.i
	mov r0, #f0004
	load r0, (r0)
_LBB0_19:                               ; %while.cond.i.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_19
	jmp _LBB0_20
_LBB0_20:                               ; %uart_putc.exit.i.i
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_21:                               ; %while.cond.i1.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_21
	jmp _LBB0_22
_LBB0_22:                               ; %uart_wait_key.exit
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_23:                               ; %while.cond.i392
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_23
	jmp _LBB0_24
_LBB0_24:                               ; %uart_putc.exit395
	mov r0, #f0003
	mov r1, #50
	store (r0), r1
_LBB0_25:                               ; %while.cond.i396
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_25
	jmp _LBB0_26
_LBB0_26:                               ; %uart_putc.exit399
	mov r0, #f0003
	mov r1, #32
	store (r0), r1
_LBB0_27:                               ; %while.cond.i.i400
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_27
	jmp _LBB0_28
_LBB0_28:                               ; %uart_putc.exit.i403
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_29:                               ; %while.cond.i1.i404
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_29
	jmp _LBB0_30
_LBB0_30:                               ; %uart_crlf.exit407
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
	mov r0, #41
	mov r8, #0
	mov r1, r8
	mov r2, r8
	call uart_check
	mov r0, #42
	mov r1, #100
	mov r2, r1
	call uart_check
	mov r0, #43
	mov r1, r8
	mov r2, r8
	call uart_check
	mov r0, #44
	imm #fff
	mov r1, #fffc0
	mov r2, r1
	call uart_check
	mov r0, #45
	mov r1, #40
	mov r2, r1
	call uart_check
_LBB0_31:                               ; %while.cond.i.i408
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_31
	jmp _LBB0_32
_LBB0_32:                               ; %gpu_clear.exit411
	mov r0, #a001c
	mov r1, #8
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_LBB0_33:                               ; %while.cond.i.i412
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_33
	jmp _LBB0_34
_LBB0_34:                               ; %gpu_tri.exit415
	mov r0, #a0000
	mov r1, #100
	store (r0), r1
	mov r0, #a0004
	mov r1, #32
	store (r0), r1
	mov r0, #a0008
	mov r1, #132
	store (r0), r1
	mov r0, #a000c
	mov r1, #c8
	store (r0), r1
	mov r0, #a0010
	mov r2, #ce
	store (r0), r2
	mov r0, #a0014
	store (r0), r1
	mov r0, #a0018
	mov r1, #f800
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_35:                               ; %while.cond.i.i416
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_35
	jmp _LBB0_36
_LBB0_36:                               ; %gpu_swap.exit419
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
_LBB0_37:                               ; %while.cond.i.i420
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_37
	jmp _LBB0_38
_LBB0_38:                               ; %uart_putc.exit.i423
	mov r0, #f0003
	mov r1, #3e
	store (r0), r1
_LBB0_39:                               ; %while.cond.i1.i424
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jz _LBB0_39
	jmp _LBB0_40
_LBB0_40:                               ; %uart_getc.exit.i427
	mov r0, #f0004
	load r0, (r0)
_LBB0_41:                               ; %while.cond.i.i.i428
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_41
	jmp _LBB0_42
_LBB0_42:                               ; %uart_putc.exit.i.i431
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_43:                               ; %while.cond.i1.i.i432
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_43
	jmp _LBB0_44
_LBB0_44:                               ; %uart_wait_key.exit435
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_45:                               ; %while.cond.i436
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_45
	jmp _LBB0_46
_LBB0_46:                               ; %uart_putc.exit439
	mov r0, #f0003
	mov r1, #50
	store (r0), r1
_LBB0_47:                               ; %while.cond.i440
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_47
	jmp _LBB0_48
_LBB0_48:                               ; %uart_putc.exit443
	mov r0, #f0003
	mov r1, #33
	store (r0), r1
_LBB0_49:                               ; %while.cond.i.i444
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_49
	jmp _LBB0_50
_LBB0_50:                               ; %uart_putc.exit.i447
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_51:                               ; %while.cond.i1.i448
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_51
	jmp _LBB0_52
_LBB0_52:                               ; %uart_crlf.exit451
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
	mov r0, #41
	mov r1, #4000
	mov r2, r1
	call uart_check
	mov r0, #42
	mov r1, #40
	mov r2, r1
	call uart_check
	mov r0, #43
	imm #fff
	mov r1, #fc000
	mov r2, r1
	call uart_check
	mov r0, #44
	imm #fff
	mov r1, #fffc0
	mov r2, r1
	call uart_check
_LBB0_53:                               ; %while.cond.i.i452
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_53
	jmp _LBB0_54
_LBB0_54:                               ; %gpu_clear.exit455
	mov r0, #a001c
	mov r1, #8
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_LBB0_55:                               ; %while.cond.i.i456
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_55
	jmp _LBB0_56
_LBB0_56:                               ; %gpu_tri.exit459
	mov r0, #a0000
	mov r1, #130
	store (r0), r1
	mov r0, #a0004
	mov r1, #32
	store (r0), r1
	mov r0, #a0008
	mov r1, #158
	store (r0), r1
	mov r0, #a000c
	mov r1, #96
	store (r0), r1
	mov r0, #a0010
	mov r2, #108
	store (r0), r2
	mov r0, #a0014
	store (r0), r1
	mov r0, #a0018
	mov r1, #7ff
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_57:                               ; %while.cond.i.i460
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_57
	jmp _LBB0_58
_LBB0_58:                               ; %gpu_tri.exit463
	mov r0, #a0000
	mov r1, #b0
	store (r0), r1
	mov r0, #a0004
	mov r1, #32
	store (r0), r1
	mov r0, #a0008
	mov r1, #d8
	store (r0), r1
	mov r0, #a000c
	mov r1, #96
	store (r0), r1
	mov r0, #a0010
	mov r2, #88
	store (r0), r2
	mov r0, #a0014
	store (r0), r1
	mov r0, #a0018
	mov r1, #f81f
	store (r0), r1
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_59:                               ; %while.cond.i.i464
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_59
	jmp _LBB0_60
_LBB0_60:                               ; %gpu_swap.exit467
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
_LBB0_61:                               ; %while.cond.i.i468
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_61
	jmp _LBB0_62
_LBB0_62:                               ; %uart_putc.exit.i471
	mov r0, #f0003
	mov r1, #3e
	store (r0), r1
_LBB0_63:                               ; %while.cond.i1.i472
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jz _LBB0_63
	jmp _LBB0_64
_LBB0_64:                               ; %uart_getc.exit.i475
	mov r0, #f0004
	load r0, (r0)
_LBB0_65:                               ; %while.cond.i.i.i476
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_65
	jmp _LBB0_66
_LBB0_66:                               ; %uart_putc.exit.i.i479
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_67:                               ; %while.cond.i1.i.i480
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_67
	jmp _LBB0_68
_LBB0_68:                               ; %uart_wait_key.exit483
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_69:                               ; %while.cond.i484
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_69
	jmp _LBB0_70
_LBB0_70:                               ; %uart_putc.exit487
	mov r0, #f0003
	mov r1, #50
	store (r0), r1
_LBB0_71:                               ; %while.cond.i488
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_71
	jmp _LBB0_72
_LBB0_72:                               ; %uart_putc.exit491
	mov r0, #f0003
	mov r1, #34
	store (r0), r1
_LBB0_73:                               ; %while.cond.i.i492
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_73
	jmp _LBB0_74
_LBB0_74:                               ; %uart_putc.exit.i495
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_75:                               ; %while.cond.i1.i496
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_75
	jmp _LBB0_76
_LBB0_76:                               ; %uart_crlf.exit499
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
	mov r0, #41
	mov r1, #aa
	mov r2, r1
	call uart_check
	mov r0, #42
	mov r1, #d8
	mov r2, r1
	call uart_check
_LBB0_77:                               ; %while.cond.i.i500
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_77
	jmp _LBB0_78
_LBB0_78:                               ; %uart_putc.exit.i503
	mov r0, #f0003
	mov r1, #3e
	store (r0), r1
_LBB0_79:                               ; %while.cond.i1.i504
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jz _LBB0_79
	jmp _LBB0_80
_LBB0_80:                               ; %uart_getc.exit.i507
	mov r0, #f0004
	load r0, (r0)
_LBB0_81:                               ; %while.cond.i.i.i508
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_81
	jmp _LBB0_82
_LBB0_82:                               ; %uart_putc.exit.i.i511
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_83:                               ; %while.cond.i1.i.i512
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_83
	jmp _LBB0_84
_LBB0_84:                               ; %uart_wait_key.exit515
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_85:                               ; %while.cond.i516
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_85
	jmp _LBB0_86
_LBB0_86:                               ; %uart_putc.exit519
	mov r0, #f0003
	mov r1, #50
	store (r0), r1
_LBB0_87:                               ; %while.cond.i520
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_87
	jmp _LBB0_88
_LBB0_88:                               ; %uart_putc.exit523
	mov r0, #f0003
	mov r1, #35
	store (r0), r1
_LBB0_89:                               ; %while.cond.i.i524
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_89
	jmp _LBB0_90
_LBB0_90:                               ; %uart_putc.exit.i527
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_91:                               ; %while.cond.i1.i528
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_91
	jmp _LBB0_92
_LBB0_92:                               ; %uart_crlf.exit531
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
	mov r8, #0
_LBB0_93:                               ; %for.body
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_109 Depth 2
                                        ;     Child Loop BB0_111 Depth 2
                                        ;     Child Loop BB0_113 Depth 2
                                        ;     Child Loop BB0_115 Depth 2
                                        ;     Child Loop BB0_117 Depth 2
	mov r11, r8
	add r11, r11
	add r11, r11
	mov r0, @vz_c
	add r0, r11
	load r12, (r0)
	mov r1, r12
	imm #800
	add r1, #12c
	add r12, #12c
	imm #800
	mov r2, #1
	mov r0, #1
	cmp r2, r1
	jc _LBB0_95
; %bb.94:                               ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r1, r0
	jmp _LBB0_96
_LBB0_95:                               ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r1, r12
_LBB0_96:                               ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, #c800
	call __udivsi3
	mov r9, r0
	mov r0, @vy_c
	add r0, r11
	load r1, (r0)
	mov r0, r9
	call __mulsi3
	mov r10, #8
	mov r1, r10
	call __ashrsi3
	imm #7ff
	mov r2, #fff78
	imm #fff
	mov r1, #fff78
	mov r3, r0
	imm #800
	xor r3, #0
	cmp r2, r3
	jc _LBB0_98
; %bb.97:                               ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r13, r1
	jmp _LBB0_99
_LBB0_98:                               ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r13, r0
_LBB0_99:                               ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, @vx_c
	add r0, r11
	load r1, (r0)
	mov r0, r9
	call __mulsi3
	mov r1, r10
	call __ashrsi3
	imm #7ff
	mov r2, #fff10
	imm #fff
	mov r1, #fff10
	mov r3, r0
	imm #800
	xor r3, #0
	cmp r2, r3
	jc _LBB0_101
; %bb.100:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, r1
	jmp _LBB0_102
_LBB0_101:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, r0
_LBB0_102:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	imm #800
	mov r2, #ef
	mov r1, #ef
	mov r3, r0
	imm #800
	xor r3, #0
	cmp r3, r2
	jc _LBB0_104
; %bb.103:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r10, r1
	jmp _LBB0_105
_LBB0_104:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r10, r0
_LBB0_105:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	imm #800
	mov r1, #87
	mov r0, #87
	mov r2, r13
	imm #800
	xor r2, #0
	cmp r2, r1
	jc _LBB0_107
; %bb.106:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r9, r0
	jmp _LBB0_108
_LBB0_107:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r9, r13
_LBB0_108:                              ; %for.body
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, r11
	add r0, #10040
	store (r0), r12
	add r9, #88
	mov r0, r11
	add r0, #10020
	store (r0), r9
	add r11, #10000
	add r10, #f0
	store (r11), r10
_LBB0_109:                              ; %while.cond.i532
                                        ;   Parent Loop BB0_93 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_109
	jmp _LBB0_110
_LBB0_110:                              ; %uart_putc.exit535
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, #f0003
	mov r1, #76
	store (r0), r1
	mov r0, r8
	call uart_putd
_LBB0_111:                              ; %while.cond.i536
                                        ;   Parent Loop BB0_93 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_111
	jmp _LBB0_112
_LBB0_112:                              ; %uart_putc.exit539
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, #f0003
	mov r1, #20
	store (r0), r1
	mov r0, r10
	call uart_putd
_LBB0_113:                              ; %while.cond.i540
                                        ;   Parent Loop BB0_93 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_113
	jmp _LBB0_114
_LBB0_114:                              ; %uart_putc.exit543
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, #f0003
	mov r1, #2c
	store (r0), r1
	mov r0, r9
	call uart_putd
_LBB0_115:                              ; %while.cond.i.i544
                                        ;   Parent Loop BB0_93 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_115
	jmp _LBB0_116
_LBB0_116:                              ; %uart_putc.exit.i547
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_117:                              ; %while.cond.i1.i548
                                        ;   Parent Loop BB0_93 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_117
	jmp _LBB0_118
_LBB0_118:                              ; %uart_crlf.exit551
                                        ;   in Loop: Header=BB0_93 Depth=1
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
	add r8, #1
	cmp r8, #8
	jnz _LBB0_93
	jmp _LBB0_119
_LBB0_119:                              ; %while.cond.i.i552
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_119
	jmp _LBB0_120
_LBB0_120:                              ; %gpu_clear.exit555
	mov r0, #a001c
	mov r1, #8
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
	mov r9, #0
_LBB0_121:                              ; %for.body53
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_123 Depth 2
	mov r10, r9
	add r10, r10
	mov r0, r10
	add r0, r0
	mov r1, @tri_a
	add r1, r0
	mov r2, @tri_b
	add r2, r0
	mov r3, @tri_c
	add r3, r0
	load r13, (r2)
	add r13, r13
	add r13, r13
	load r0, (r1)
	add r0, r0
	add r0, r0
	mov r1, r0
	add r1, #10020
	add r0, #10000
	load r8, (r0)
	mov r0, r13
	add r0, #10000
	load r2, (r0)
	load r11, (r1)
	load r12, (r3)
	add r12, r12
	add r12, r12
	mov r0, r12
	add r0, #10020
	load r0, (r0)
	mov r7, r14
	add r7, #1c
	store (r7), r0                          ; 4-byte Folded Spill
	sub r0, r11
	mov r7, r14
	add r7, #20
	store (r7), r2                          ; 4-byte Folded Spill
	mov r1, r2
	sub r1, r8
	call __mulsi3
	mov r7, r14
	add r7, #24
	store (r7), r0                          ; 4-byte Folded Spill
	add r13, #10020
	load r0, (r13)
	add r12, #10000
	load r13, (r12)
	mov r12, r8
	mov r8, r0
	mov r0, r12
	sub r0, r13
	mov r1, r8
	sub r1, r11
	call __mulsi3
	mov r7, r14
	add r7, #24
	load r1, (r7)                           ; 4-byte Folded Reload
	add r0, r1
	imm #800
	xor r0, #0
	imm #800
	cmp r0, #1
	jc _LBB0_125
	jmp _LBB0_122
_LBB0_122:                              ; %if.end74
                                        ;   in Loop: Header=BB0_121 Depth=1
	imm #fff
	and r10, #ffffc
	mov r0, @face_col
	add r0, r10
	load r0, (r0)
_LBB0_123:                              ; %while.cond.i.i556
                                        ;   Parent Loop BB0_121 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r1, #a0024
	load r1, (r1)
	and r1, #1
	cmp r1, #0
	jnz _LBB0_123
	jmp _LBB0_124
_LBB0_124:                              ; %gpu_tri.exit559
                                        ;   in Loop: Header=BB0_121 Depth=1
	mov r1, #a0000
	store (r1), r12
	mov r1, #a0004
	store (r1), r11
	mov r1, #a0008
	mov r7, r14
	add r7, #20
	load r2, (r7)                           ; 4-byte Folded Reload
	store (r1), r2
	mov r1, #a000c
	store (r1), r8
	mov r1, #a0010
	store (r1), r13
	mov r1, #a0014
	mov r7, r14
	add r7, #1c
	load r2, (r7)                           ; 4-byte Folded Reload
	store (r1), r2
	mov r1, #a0018
	store (r1), r0
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_125:                              ; %cleanup
                                        ;   in Loop: Header=BB0_121 Depth=1
	add r9, #1
	cmp r9, #c
	jnz _LBB0_121
	jmp _LBB0_126
_LBB0_126:                              ; %while.cond.i.i560
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_126
	jmp _LBB0_127
_LBB0_127:                              ; %gpu_swap.exit563
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
_LBB0_128:                              ; %while.cond.i.i564
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_128
	jmp _LBB0_129
_LBB0_129:                              ; %uart_putc.exit.i567
	mov r0, #f0003
	mov r1, #3e
	store (r0), r1
_LBB0_130:                              ; %while.cond.i1.i568
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jz _LBB0_130
	jmp _LBB0_131
_LBB0_131:                              ; %uart_getc.exit.i571
	mov r0, #f0004
	load r0, (r0)
_LBB0_132:                              ; %while.cond.i.i.i572
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_132
	jmp _LBB0_133
_LBB0_133:                              ; %uart_putc.exit.i.i575
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_134:                              ; %while.cond.i1.i.i576
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_134
	jmp _LBB0_135
_LBB0_135:                              ; %uart_wait_key.exit579
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_136:                              ; %while.cond.i580
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_136
	jmp _LBB0_137
_LBB0_137:                              ; %uart_putc.exit583
	mov r0, #f0003
	mov r1, #50
	store (r0), r1
_LBB0_138:                              ; %while.cond.i584
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_138
	jmp _LBB0_139
_LBB0_139:                              ; %uart_putc.exit587
	mov r0, #f0003
	mov r1, #36
	store (r0), r1
_LBB0_140:                              ; %while.cond.i.i588
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_140
	jmp _LBB0_141
_LBB0_141:                              ; %uart_putc.exit.i591
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB0_142:                              ; %while.cond.i1.i592
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB0_142
	jmp _LBB0_143
_LBB0_143:                              ; %uart_crlf.exit595
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
_LBB0_144:                              ; %while.cond.i.i596
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_144
	jmp _LBB0_145
_LBB0_145:                              ; %gpu_clear.exit599
	mov r0, #a001c
	mov r1, #8
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
_LBB0_146:                              ; %while.cond.i.i600
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_146
	jmp _LBB0_147
_LBB0_147:                              ; %gpu_swap.exit603
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
	mov r2, #0
	mov r4, r2
_LBB0_148:                              ; %for.cond90
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB0_149 Depth 2
                                        ;     Child Loop BB0_151 Depth 2
                                        ;     Child Loop BB0_168 Depth 2
                                        ;     Child Loop BB0_170 Depth 2
                                        ;       Child Loop BB0_171 Depth 3
                                        ;     Child Loop BB0_176 Depth 2
                                        ;       Child Loop BB0_178 Depth 3
                                        ;     Child Loop BB0_181 Depth 2
	mov r0, r4
	add r0, #40
	and r0, #ff
	add r0, r0
	mov r1, r2
	add r1, r1
	add r1, r1
	add r0, r0
	mov r7, r14
	add r7, #8
	store (r7), r2                          ; 4-byte Folded Spill
	add r2, #40
	and r2, #ff
	add r2, r2
	add r2, r2
	mov r3, @sin_tab
	add r2, r3
	add r0, r3
	add r1, r3
	mov r7, r14
	add r7, #4
	store (r7), r4                          ; 4-byte Folded Spill
	add r4, r4
	add r4, r4
	add r4, r3
	load r3, (r4)
	mov r7, r14
	add r7, #c
	store (r7), r3                          ; 4-byte Folded Spill
	load r1, (r1)
	mov r7, r14
	add r7, #24
	store (r7), r1                          ; 4-byte Folded Spill
	load r0, (r0)
	mov r7, r14
	add r7, #20
	store (r7), r0                          ; 4-byte Folded Spill
	load r0, (r2)
	mov r7, r14
	add r7, #1c
	store (r7), r0                          ; 4-byte Folded Spill
_LBB0_149:                              ; %while.cond.i.i604
                                        ;   Parent Loop BB0_148 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_149
	jmp _LBB0_150
_LBB0_150:                              ; %gpu_clear.exit607
                                        ;   in Loop: Header=BB0_148 Depth=1
	mov r0, #a001c
	mov r1, #8
	store (r0), r1
	mov r0, #a0020
	mov r1, #2
	store (r0), r1
	mov r11, #0
_LBB0_151:                              ; %for.body106
                                        ;   Parent Loop BB0_148 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r9, @vz_c
	add r9, r11
	mov r0, @vx_c
	add r0, r11
	load r0, (r0)
	mov r7, r14
	add r7, #18
	store (r7), r0                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #24
	load r1, (r7)                           ; 4-byte Folded Reload
	call __mulsi3
	mov r8, r0
	load r0, (r9)
	mov r7, r14
	add r7, #14
	store (r7), r0                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #1c
	load r1, (r7)                           ; 4-byte Folded Reload
	call __mulsi3
	add r0, r8
	mov r13, #8
	mov r1, r13
	call __ashrsi3
	mov r8, r0
	mov r7, r14
	add r7, #c
	load r9, (r7)                           ; 4-byte Folded Reload
	mov r1, r9
	call __mulsi3
	mov r7, r14
	add r7, #10
	store (r7), r0                          ; 4-byte Folded Spill
	mov r0, r8
	mov r7, r14
	add r7, #20
	load r1, (r7)                           ; 4-byte Folded Reload
	call __mulsi3
	mov r8, r0
	mov r0, @vy_c
	add r0, r11
	load r10, (r0)
	mov r0, r10
	mov r1, r9
	call __mulsi3
	add r0, r8
	mov r1, r13
	call __ashrsi3
	mov r12, r0
	mov r1, r12
	imm #800
	add r1, #12c
	add r12, #12c
	imm #800
	mov r2, #1
	mov r0, #1
	cmp r2, r1
	jc _LBB0_153
; %bb.152:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r8, r0
	jmp _LBB0_154
_LBB0_153:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r8, r12
_LBB0_154:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r0, r10
	mov r7, r14
	add r7, #20
	load r1, (r7)                           ; 4-byte Folded Reload
	call __mulsi3
	mov r9, r0
	mov r0, #c800
	mov r1, r8
	call __udivsi3
	mov r10, r0
	mov r7, r14
	add r7, #10
	load r0, (r7)                           ; 4-byte Folded Reload
	sub r9, r0
	mov r0, r9
	mov r1, r13
	call __ashrsi3
	mov r1, r10
	call __mulsi3
	mov r1, r13
	call __ashrsi3
	imm #7ff
	mov r2, #fff78
	imm #fff
	mov r1, #fff78
	mov r3, r0
	imm #800
	xor r3, #0
	cmp r2, r3
	jc _LBB0_156
; %bb.155:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r9, r1
	mov r7, r14
	add r7, #18
	load r0, (r7)                           ; 4-byte Folded Reload
	jmp _LBB0_157
_LBB0_156:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r9, r0
	mov r7, r14
	add r7, #18
	load r0, (r7)                           ; 4-byte Folded Reload
_LBB0_157:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r7, r14
	add r7, #1c
	load r1, (r7)                           ; 4-byte Folded Reload
	call __mulsi3
	mov r8, r0
	mov r7, r14
	add r7, #14
	load r0, (r7)                           ; 4-byte Folded Reload
	mov r7, r14
	add r7, #24
	load r1, (r7)                           ; 4-byte Folded Reload
	call __mulsi3
	sub r8, r0
	mov r0, r8
	mov r1, r13
	call __ashrsi3
	mov r1, r10
	call __mulsi3
	mov r1, r13
	call __ashrsi3
	imm #7ff
	mov r2, #fff10
	imm #fff
	mov r1, #fff10
	mov r3, r0
	imm #800
	xor r3, #0
	cmp r2, r3
	jc _LBB0_159
; %bb.158:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r0, r1
	jmp _LBB0_160
_LBB0_159:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r0, r0
_LBB0_160:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	imm #800
	mov r2, #ef
	mov r1, #ef
	mov r3, r0
	imm #800
	xor r3, #0
	cmp r3, r2
	jc _LBB0_162
; %bb.161:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r0, r1
	jmp _LBB0_163
_LBB0_162:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r0, r0
_LBB0_163:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	imm #800
	mov r2, #87
	mov r1, #87
	mov r3, r9
	imm #800
	xor r3, #0
	cmp r3, r2
	jc _LBB0_165
; %bb.164:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r1, r1
	jmp _LBB0_166
_LBB0_165:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r1, r9
_LBB0_166:                              ; %for.body106
                                        ;   in Loop: Header=BB0_151 Depth=2
	mov r2, r11
	add r2, #10040
	store (r2), r12
	add r1, #88
	mov r2, r11
	add r2, #10020
	store (r2), r1
	add r0, #f0
	mov r1, r11
	add r1, #10000
	store (r1), r0
	add r11, #4
	cmp r11, #20
	jnz _LBB0_151
	jmp _LBB0_167
_LBB0_167:                              ; %for.body168.preheader
                                        ;   in Loop: Header=BB0_148 Depth=1
	mov r0, #0
	mov r1, #10090
	mov r2, #10060
	mov r3, @tri_a
	mov r4, @tri_b
	mov r5, @tri_c
_LBB0_168:                              ; %for.body168
                                        ;   Parent Loop BB0_148 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	load r6, (r3)
	add r6, r6
	add r6, r6
	add r6, #10040
	load r6, (r6)
	load r7, (r4)
	add r7, r7
	add r7, r7
	add r7, #10040
	load r7, (r7)
	add r7, r6
	load r6, (r5)
	add r6, r6
	add r6, r6
	add r6, #10040
	load r6, (r6)
	add r6, r7
	store (r2), r6
	add r5, #4
	add r4, #4
	add r3, #4
	add r2, #4
	store (r1), r0
	add r1, #4
	add r0, #1
	cmp r0, #c
	jnz _LBB0_168
	jmp _LBB0_169
_LBB0_169:                              ; %for.body184.preheader
                                        ;   in Loop: Header=BB0_148 Depth=1
	mov r0, #1
	mov r1, #2
	mov r2, #10094
_LBB0_170:                              ; %for.body184
                                        ;   Parent Loop BB0_148 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB0_171 Depth 3
	mov r3, r0
	add r3, r3
	add r3, r3
	add r3, #10090
	load r3, (r3)
	mov r4, r3
	add r4, r4
	add r4, r4
	add r4, #10060
	load r4, (r4)
	imm #800
	xor r4, #0
	mov r7, r2
	mov r5, r1
	mov r6, r7
_LBB0_171:                              ; %land.rhs
                                        ;   Parent Loop BB0_148 Depth=1
                                        ;     Parent Loop BB0_170 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	imm #fff
	add r6, #ffffc
	load r8, (r6)
	mov r9, r8
	add r9, r9
	add r9, r9
	add r9, #10060
	load r9, (r9)
	imm #800
	xor r9, #0
	cmp r9, r4
	jnc _LBB0_173
	jmp _LBB0_172
_LBB0_172:                              ; %while.body
                                        ;   in Loop: Header=BB0_171 Depth=3
	store (r7), r8
	mov r8, #0
	mov r9, r5
	imm #fff
	add r9, #fffff
	imm #7ff
	add r5, #fffff
	imm #800
	mov r7, #1
	cmp r7, r5
	mov r7, r6
	mov r5, r9
	jc _LBB0_171
	jmp _LBB0_174
_LBB0_173:                              ; %land.rhs.while.end_crit_edge
                                        ;   in Loop: Header=BB0_170 Depth=2
	imm #fff
	add r5, #fffff
	mov r8, r5
_LBB0_174:                              ; %while.end
                                        ;   in Loop: Header=BB0_170 Depth=2
	add r8, r8
	add r8, r8
	add r8, #10090
	store (r8), r3
	add r2, #4
	add r1, #1
	add r0, #1
	cmp r0, #c
	jnz _LBB0_170
	jmp _LBB0_175
_LBB0_175:                              ; %for.body203.preheader
                                        ;   in Loop: Header=BB0_148 Depth=1
	mov r9, #0
_LBB0_176:                              ; %for.body203
                                        ;   Parent Loop BB0_148 Depth=1
                                        ; =>  This Loop Header: Depth=2
                                        ;       Child Loop BB0_178 Depth 3
	mov r0, r9
	add r0, r0
	add r0, r0
	add r0, #10090
	load r10, (r0)
	add r10, r10
	mov r0, r10
	add r0, r0
	mov r1, @tri_a
	add r1, r0
	mov r2, @tri_b
	add r2, r0
	mov r3, @tri_c
	add r3, r0
	load r13, (r2)
	add r13, r13
	add r13, r13
	load r0, (r1)
	add r0, r0
	add r0, r0
	mov r1, r0
	add r1, #10020
	add r0, #10000
	load r8, (r0)
	mov r0, r13
	add r0, #10000
	load r2, (r0)
	load r11, (r1)
	load r12, (r3)
	add r12, r12
	add r12, r12
	mov r0, r12
	add r0, #10020
	load r0, (r0)
	mov r7, r14
	add r7, #1c
	store (r7), r0                          ; 4-byte Folded Spill
	sub r0, r11
	mov r7, r14
	add r7, #20
	store (r7), r2                          ; 4-byte Folded Spill
	mov r1, r2
	sub r1, r8
	call __mulsi3
	mov r7, r14
	add r7, #24
	store (r7), r0                          ; 4-byte Folded Spill
	add r13, #10020
	load r0, (r13)
	add r12, #10000
	load r13, (r12)
	mov r12, r8
	mov r8, r0
	mov r0, r12
	sub r0, r13
	mov r1, r8
	sub r1, r11
	call __mulsi3
	mov r7, r14
	add r7, #24
	load r1, (r7)                           ; 4-byte Folded Reload
	add r0, r1
	imm #800
	xor r0, #0
	imm #800
	cmp r0, #1
	jc _LBB0_180
	jmp _LBB0_177
_LBB0_177:                              ; %if.end230
                                        ;   in Loop: Header=BB0_176 Depth=2
	imm #fff
	and r10, #ffffc
	mov r0, @face_col
	add r0, r10
	load r0, (r0)
_LBB0_178:                              ; %while.cond.i.i608
                                        ;   Parent Loop BB0_148 Depth=1
                                        ;     Parent Loop BB0_176 Depth=2
                                        ; =>    This Inner Loop Header: Depth=3
	mov r1, #a0024
	load r1, (r1)
	and r1, #1
	cmp r1, #0
	jnz _LBB0_178
	jmp _LBB0_179
_LBB0_179:                              ; %gpu_tri.exit611
                                        ;   in Loop: Header=BB0_176 Depth=2
	mov r1, #a0000
	store (r1), r12
	mov r1, #a0004
	store (r1), r11
	mov r1, #a0008
	mov r7, r14
	add r7, #20
	load r2, (r7)                           ; 4-byte Folded Reload
	store (r1), r2
	mov r1, #a000c
	store (r1), r8
	mov r1, #a0010
	store (r1), r13
	mov r1, #a0014
	mov r7, r14
	add r7, #1c
	load r2, (r7)                           ; 4-byte Folded Reload
	store (r1), r2
	mov r1, #a0018
	store (r1), r0
	mov r0, #a0020
	mov r1, #1
	store (r0), r1
_LBB0_180:                              ; %cleanup239
                                        ;   in Loop: Header=BB0_176 Depth=2
	add r9, #1
	cmp r9, #c
	jnz _LBB0_176
	jmp _LBB0_181
_LBB0_181:                              ; %while.cond.i.i612
                                        ;   Parent Loop BB0_148 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r0, #a0024
	load r0, (r0)
	and r0, #1
	cmp r0, #0
	jnz _LBB0_181
	jmp _LBB0_182
_LBB0_182:                              ; %gpu_swap.exit615
                                        ;   in Loop: Header=BB0_148 Depth=1
	mov r0, #a0020
	mov r1, #3
	store (r0), r1
	mov r7, r14
	add r7, #8
	load r2, (r7)                           ; 4-byte Folded Reload
	add r2, #2
	and r2, #ff
	mov r7, r14
	add r7, #4
	load r4, (r7)                           ; 4-byte Folded Reload
	add r4, #1
	and r4, #ff
	jmp _LBB0_148
                                        ; -- End function
uart_check:                             ; -- Begin function uart_check
                                        ; @uart_check
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
	mov r9, r1
_LBB1_1:                                ; %while.cond.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #f0002
	load r1, (r1)
	and r1, #4
	cmp r1, #0
	jnz _LBB1_1
	jmp _LBB1_2
_LBB1_2:                                ; %uart_putc.exit
	mov r1, #f0003
	mov r2, #20
	store (r1), r2
_LBB1_3:                                ; %while.cond.i3
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #f0002
	load r1, (r1)
	and r1, #4
	cmp r1, #0
	jnz _LBB1_3
	jmp _LBB1_4
_LBB1_4:                                ; %uart_putc.exit6
	mov r1, #f0003
	mov r2, #20
	store (r1), r2
_LBB1_5:                                ; %while.cond.i7
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #f0002
	load r1, (r1)
	and r1, #4
	cmp r1, #0
	jnz _LBB1_5
	jmp _LBB1_6
_LBB1_6:                                ; %uart_putc.exit10
	mov r1, #f0003
	store (r1), r0
_LBB1_7:                                ; %while.cond.i11
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_7
	jmp _LBB1_8
_LBB1_8:                                ; %uart_putc.exit14
	mov r0, #f0003
	mov r1, #3d
	store (r0), r1
	mov r0, r9
	call uart_putd
_LBB1_9:                                ; %while.cond.i15
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_9
	jmp _LBB1_10
_LBB1_10:                               ; %uart_putc.exit18
	mov r0, #f0003
	mov r1, #20
	store (r0), r1
_LBB1_11:                               ; %while.cond.i19
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_11
	jmp _LBB1_12
_LBB1_12:                               ; %uart_putc.exit22
	mov r0, #f0003
	mov r1, #65
	store (r0), r1
_LBB1_13:                               ; %while.cond.i23
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_13
	jmp _LBB1_14
_LBB1_14:                               ; %uart_putc.exit26
	mov r0, #f0003
	mov r1, #78
	store (r0), r1
_LBB1_15:                               ; %while.cond.i27
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_15
	jmp _LBB1_16
_LBB1_16:                               ; %uart_putc.exit30
	mov r0, #f0003
	mov r1, #70
	store (r0), r1
_LBB1_17:                               ; %while.cond.i31
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_17
	jmp _LBB1_18
_LBB1_18:                               ; %uart_putc.exit34
	mov r0, #f0003
	mov r1, #3d
	store (r0), r1
	mov r0, r8
	call uart_putd
	cmp r9, r8
	jz _LBB1_20
	jmp _LBB1_19
_LBB1_20:                               ; %while.cond.i35
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_20
	jmp _LBB1_21
_LBB1_21:                               ; %uart_putc.exit38
	mov r0, #f0003
	mov r1, #20
	store (r0), r1
_LBB1_22:                               ; %while.cond.i39
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_22
	jmp _LBB1_23
_LBB1_23:                               ; %uart_putc.exit42
	mov r0, #f0003
	mov r1, #4f
	store (r0), r1
_LBB1_24:                               ; %while.cond.i43
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #4b
	mov r1, #f0002
	load r1, (r1)
	and r1, #4
	cmp r1, #0
	jz _LBB1_34
	jmp _LBB1_24
_LBB1_19:                               ; %while.cond.i47.preheader
	jmp _LBB1_25
_LBB1_25:                               ; %while.cond.i47
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_25
	jmp _LBB1_26
_LBB1_26:                               ; %uart_putc.exit50
	mov r0, #f0003
	mov r1, #20
	store (r0), r1
_LBB1_27:                               ; %while.cond.i51
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_27
	jmp _LBB1_28
_LBB1_28:                               ; %uart_putc.exit54
	mov r0, #f0003
	mov r1, #46
	store (r0), r1
_LBB1_29:                               ; %while.cond.i55
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_29
	jmp _LBB1_30
_LBB1_30:                               ; %uart_putc.exit58
	mov r0, #f0003
	mov r1, #41
	store (r0), r1
_LBB1_31:                               ; %while.cond.i59
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_31
	jmp _LBB1_32
_LBB1_32:                               ; %uart_putc.exit62
	mov r0, #f0003
	mov r1, #49
	store (r0), r1
_LBB1_33:                               ; %while.cond.i63
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #4c
	mov r1, #f0002
	load r1, (r1)
	and r1, #4
	cmp r1, #0
	jnz _LBB1_33
	jmp _LBB1_34
_LBB1_34:                               ; %if.end
	mov r1, #f0003
	store (r1), r0
_LBB1_35:                               ; %while.cond.i.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_35
	jmp _LBB1_36
_LBB1_36:                               ; %uart_putc.exit.i
	mov r0, #f0003
	mov r1, #d
	store (r0), r1
_LBB1_37:                               ; %while.cond.i1.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB1_37
	jmp _LBB1_38
_LBB1_38:                               ; %uart_crlf.exit
	mov r0, #f0003
	mov r1, #a
	store (r0), r1
	mov r7, r14
	add r7, #4
	load r15, (r7)                          ; 4-byte Folded Reload
	mov r7, r14
	add r7, #8
	load r9, (r7)                           ; 4-byte Folded Reload
	mov r7, r14
	add r7, #c
	load r8, (r7)                           ; 4-byte Folded Reload
	add r14, #10
	ret
                                        ; -- End function
uart_putd:                              ; -- Begin function uart_putd
                                        ; @uart_putd
; %bb.0:                                ; %entry
	sub r14, #30
	mov r7, r14
	add r7, #2c
	store (r7), r8                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #28
	store (r7), r9                          ; 4-byte Folded Spill
	mov r7, r14
	add r7, #24
	store (r7), r15                         ; 4-byte Folded Spill
	mov r1, r0
	imm #800
	xor r1, #0
	imm #7ff
	mov r2, #fffff
	cmp r2, r1
	jc _LBB2_12
	jmp _LBB2_1
_LBB2_12:                               ; %if.else
	cmp r0, #0
	jz _LBB2_14
	jmp _LBB2_13
_LBB2_13:                               ; %while.body.i6.preheader
	imm #fff
	mov r8, #fffff
	mov r7, r14
	add r7, #4
	add r9, #0
	jmp _LBB2_16
_LBB2_16:                               ; %while.body.i6
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, r0
	and r1, #f
	store (r9), r1
	mov r1, #4
	call __lshrsi3
	add r9, #4
	add r8, #1
	cmp r0, #0
	jnz _LBB2_16
	jmp _LBB2_17
_LBB2_17:                               ; %while.body7.i14.preheader
	mov r7, r14
	add r7, #4
	add r0, #0
_LBB2_18:                               ; %while.body7.i14
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB2_19 Depth 2
	mov r1, r8
	mov r2, r1
	add r2, r2
	add r2, r2
	add r2, r0
	load r2, (r2)
_LBB2_19:                               ; %while.cond.i29.i17
                                        ;   Parent Loop BB2_18 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r3, #f0002
	load r3, (r3)
	and r3, #4
	cmp r3, #0
	jnz _LBB2_19
	jmp _LBB2_20
_LBB2_20:                               ; %uart_putc.exit32.i20
                                        ;   in Loop: Header=BB2_18 Depth=1
	mov r5, r2
	imm #800
	xor r5, #0
	imm #800
	mov r6, #a
	mov r3, #57
	mov r4, #30
	cmp r5, r6
	jc _LBB2_22
; %bb.21:                               ; %uart_putc.exit32.i20
                                        ;   in Loop: Header=BB2_18 Depth=1
	mov r3, r3
	jmp _LBB2_23
_LBB2_22:                               ; %uart_putc.exit32.i20
                                        ;   in Loop: Header=BB2_18 Depth=1
	mov r3, r4
_LBB2_23:                               ; %uart_putc.exit32.i20
                                        ;   in Loop: Header=BB2_18 Depth=1
	add r3, r2
	mov r2, #f0003
	store (r2), r3
	mov r8, r1
	imm #fff
	add r8, #fffff
	imm #800
	xor r1, #0
	imm #800
	mov r2, #0
	cmp r2, r1
	jc _LBB2_18
	jmp _LBB2_24
_LBB2_1:                                ; %while.cond.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, #f0002
	load r1, (r1)
	and r1, #4
	cmp r1, #0
	jnz _LBB2_1
	jmp _LBB2_2
_LBB2_2:                                ; %uart_putc.exit
	mov r1, #f0003
	mov r2, #2d
	store (r1), r2
	mov r1, #0
	sub r1, r0
	mov r0, r1
	imm #fff
	mov r8, #fffff
	mov r7, r14
	add r7, #4
	add r9, #0
_LBB2_3:                                ; %while.body.i
                                        ; =>This Inner Loop Header: Depth=1
	mov r1, r0
	and r1, #f
	store (r9), r1
	mov r1, #4
	call __lshrsi3
	add r9, #4
	add r8, #1
	cmp r0, #0
	jnz _LBB2_3
	jmp _LBB2_4
_LBB2_4:                                ; %while.body7.i.preheader
	mov r7, r14
	add r7, #4
	add r0, #0
_LBB2_5:                                ; %while.body7.i
                                        ; =>This Loop Header: Depth=1
                                        ;     Child Loop BB2_6 Depth 2
	mov r1, r8
	mov r2, r1
	add r2, r2
	add r2, r2
	add r2, r0
	load r2, (r2)
_LBB2_6:                                ; %while.cond.i29.i
                                        ;   Parent Loop BB2_5 Depth=1
                                        ; =>  This Inner Loop Header: Depth=2
	mov r3, #f0002
	load r3, (r3)
	and r3, #4
	cmp r3, #0
	jnz _LBB2_6
	jmp _LBB2_7
_LBB2_7:                                ; %uart_putc.exit32.i
                                        ;   in Loop: Header=BB2_5 Depth=1
	mov r5, r2
	imm #800
	xor r5, #0
	imm #800
	mov r6, #a
	mov r3, #57
	mov r4, #30
	cmp r5, r6
	jc _LBB2_9
; %bb.8:                                ; %uart_putc.exit32.i
                                        ;   in Loop: Header=BB2_5 Depth=1
	mov r3, r3
	jmp _LBB2_10
_LBB2_9:                                ; %uart_putc.exit32.i
                                        ;   in Loop: Header=BB2_5 Depth=1
	mov r3, r4
_LBB2_10:                               ; %uart_putc.exit32.i
                                        ;   in Loop: Header=BB2_5 Depth=1
	add r3, r2
	mov r2, #f0003
	store (r2), r3
	mov r8, r1
	imm #fff
	add r8, #fffff
	imm #800
	xor r1, #0
	imm #800
	mov r2, #0
	cmp r2, r1
	jc _LBB2_5
	jmp _LBB2_11
_LBB2_11:                               ; %uart_puth.exit
	jmp _LBB2_24
_LBB2_14:                               ; %while.cond.i.i26
                                        ; =>This Inner Loop Header: Depth=1
	mov r0, #f0002
	load r0, (r0)
	and r0, #4
	cmp r0, #0
	jnz _LBB2_14
	jmp _LBB2_15
_LBB2_15:                               ; %uart_putc.exit.i29
	mov r0, #f0003
	mov r1, #30
	store (r0), r1
	jmp _LBB2_24
_LBB2_24:                               ; %if.end
	mov r7, r14
	add r7, #24
	load r15, (r7)                          ; 4-byte Folded Reload
	mov r7, r14
	add r7, #28
	load r9, (r7)                           ; 4-byte Folded Reload
	mov r7, r14
	add r7, #2c
	load r8, (r7)                           ; 4-byte Folded Reload
	add r14, #30
	ret
                                        ; -- End function
sin_tab:
	.dd 0
	.dd 6
	.dd 13
	.dd 19
	.dd 25
	.dd 31
	.dd 38
	.dd 44
	.dd 50
	.dd 56
	.dd 62
	.dd 68
	.dd 74
	.dd 80
	.dd 86
	.dd 92
	.dd 98
	.dd 104
	.dd 109
	.dd 115
	.dd 121
	.dd 126
	.dd 132
	.dd 137
	.dd 142
	.dd 147
	.dd 152
	.dd 157
	.dd 162
	.dd 167
	.dd 171
	.dd 176
	.dd 180
	.dd 185
	.dd 189
	.dd 193
	.dd 197
	.dd 201
	.dd 205
	.dd 208
	.dd 212
	.dd 215
	.dd 219
	.dd 222
	.dd 225
	.dd 228
	.dd 231
	.dd 234
	.dd 236
	.dd 239
	.dd 241
	.dd 243
	.dd 245
	.dd 247
	.dd 248
	.dd 250
	.dd 251
	.dd 252
	.dd 253
	.dd 254
	.dd 255
	.dd 255
	.dd 256
	.dd 256
	.dd 256
	.dd 256
	.dd 256
	.dd 255
	.dd 255
	.dd 254
	.dd 253
	.dd 252
	.dd 251
	.dd 250
	.dd 248
	.dd 247
	.dd 245
	.dd 243
	.dd 241
	.dd 239
	.dd 236
	.dd 234
	.dd 231
	.dd 228
	.dd 225
	.dd 222
	.dd 219
	.dd 215
	.dd 212
	.dd 208
	.dd 205
	.dd 201
	.dd 197
	.dd 193
	.dd 189
	.dd 185
	.dd 180
	.dd 176
	.dd 171
	.dd 167
	.dd 162
	.dd 157
	.dd 152
	.dd 147
	.dd 142
	.dd 137
	.dd 132
	.dd 126
	.dd 121
	.dd 115
	.dd 109
	.dd 104
	.dd 98
	.dd 92
	.dd 86
	.dd 80
	.dd 74
	.dd 68
	.dd 62
	.dd 56
	.dd 50
	.dd 44
	.dd 38
	.dd 31
	.dd 25
	.dd 19
	.dd 13
	.dd 6
	.dd 0
	.dd 4294967290
	.dd 4294967283
	.dd 4294967277
	.dd 4294967271
	.dd 4294967265
	.dd 4294967258
	.dd 4294967252
	.dd 4294967246
	.dd 4294967240
	.dd 4294967234
	.dd 4294967228
	.dd 4294967222
	.dd 4294967216
	.dd 4294967210
	.dd 4294967204
	.dd 4294967198
	.dd 4294967192
	.dd 4294967187
	.dd 4294967181
	.dd 4294967175
	.dd 4294967170
	.dd 4294967164
	.dd 4294967159
	.dd 4294967154
	.dd 4294967149
	.dd 4294967144
	.dd 4294967139
	.dd 4294967134
	.dd 4294967129
	.dd 4294967125
	.dd 4294967120
	.dd 4294967116
	.dd 4294967111
	.dd 4294967107
	.dd 4294967103
	.dd 4294967099
	.dd 4294967095
	.dd 4294967091
	.dd 4294967088
	.dd 4294967084
	.dd 4294967081
	.dd 4294967077
	.dd 4294967074
	.dd 4294967071
	.dd 4294967068
	.dd 4294967065
	.dd 4294967062
	.dd 4294967060
	.dd 4294967057
	.dd 4294967055
	.dd 4294967053
	.dd 4294967051
	.dd 4294967049
	.dd 4294967048
	.dd 4294967046
	.dd 4294967045
	.dd 4294967044
	.dd 4294967043
	.dd 4294967042
	.dd 4294967041
	.dd 4294967041
	.dd 4294967040
	.dd 4294967040
	.dd 4294967040
	.dd 4294967040
	.dd 4294967040
	.dd 4294967041
	.dd 4294967041
	.dd 4294967042
	.dd 4294967043
	.dd 4294967044
	.dd 4294967045
	.dd 4294967046
	.dd 4294967048
	.dd 4294967049
	.dd 4294967051
	.dd 4294967053
	.dd 4294967055
	.dd 4294967057
	.dd 4294967060
	.dd 4294967062
	.dd 4294967065
	.dd 4294967068
	.dd 4294967071
	.dd 4294967074
	.dd 4294967077
	.dd 4294967081
	.dd 4294967084
	.dd 4294967088
	.dd 4294967091
	.dd 4294967095
	.dd 4294967099
	.dd 4294967103
	.dd 4294967107
	.dd 4294967111
	.dd 4294967116
	.dd 4294967120
	.dd 4294967125
	.dd 4294967129
	.dd 4294967134
	.dd 4294967139
	.dd 4294967144
	.dd 4294967149
	.dd 4294967154
	.dd 4294967159
	.dd 4294967164
	.dd 4294967170
	.dd 4294967175
	.dd 4294967181
	.dd 4294967187
	.dd 4294967192
	.dd 4294967198
	.dd 4294967204
	.dd 4294967210
	.dd 4294967216
	.dd 4294967222
	.dd 4294967228
	.dd 4294967234
	.dd 4294967240
	.dd 4294967246
	.dd 4294967252
	.dd 4294967258
	.dd 4294967265
	.dd 4294967271
	.dd 4294967277
	.dd 4294967283
	.dd 4294967290
vx_c:
	.dd 4294967232
	.dd 64
	.dd 64
	.dd 4294967232
	.dd 4294967232
	.dd 64
	.dd 64
	.dd 4294967232
vy_c:
	.dd 4294967232
	.dd 4294967232
	.dd 64
	.dd 64
	.dd 4294967232
	.dd 4294967232
	.dd 64
	.dd 64
vz_c:
	.dd 4294967232
	.dd 4294967232
	.dd 4294967232
	.dd 4294967232
	.dd 64
	.dd 64
	.dd 64
	.dd 64
tri_a:
	.dd 0
	.dd 0
	.dd 5
	.dd 5
	.dd 4
	.dd 4
	.dd 1
	.dd 1
	.dd 3
	.dd 3
	.dd 4
	.dd 4
tri_b:
	.dd 1
	.dd 2
	.dd 4
	.dd 7
	.dd 0
	.dd 3
	.dd 5
	.dd 6
	.dd 2
	.dd 6
	.dd 5
	.dd 1
tri_c:
	.dd 2
	.dd 3
	.dd 7
	.dd 6
	.dd 3
	.dd 7
	.dd 6
	.dd 2
	.dd 6
	.dd 7
	.dd 1
	.dd 0
face_col:
	.dd 63488
	.dd 2016
	.dd 31
	.dd 65504
	.dd 63519
	.dd 2047
