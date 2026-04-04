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
