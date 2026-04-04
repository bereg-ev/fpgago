; test_gfx.asm — GPU3D basic graphics test: rectangles + diagonal lines
;
; Assemble with:
;   cd project/risc2-video
;   ../../asm-compiler/gcasm -crisc2 gpu3d_demo/test_gfx.asm
; Then rebuild and run the simulation:
;   cd sim-desktop && make run
;
; What it draws (static scene, no animation):
;   1. Clear to dark blue background
;   2. Red rectangle        (50,30)-(200,100)
;   3. Green rectangle      (220,30)-(430,100)
;   4. Yellow rectangle     (100,140)-(380,230)
;   5. Diagonal line (white) from (10,10) to (470,260)  (thin triangle)
;   6. Diagonal line (cyan)  from (470,10) to (10,260)  (thin triangle)
;   7. Swap buffers to display
;   8. Halt (infinite loop)
;
; GPU registers (byte addresses):
;   V0_X=0A0000  V0_Y=0A0004  V1_X=0A0008  V1_Y=0A000C
;   V2_X=0A0010  V2_Y=0A0014  TRI_COLOR=0A0018  CLEAR_COLOR=0A001C
;   CMD=0A0020   STATUS=0A0024
;
; Commands: 1=DRAW_TRI, 2=CLEAR_FB, 3=SWAP_BUFFERS

; ── Reset / interrupt vectors ────────────────────────────────────────────────
reset:
	jmp   start
	jmp   timerIrq
	.dd   0, 0, 0, 0, 0, 0

timerIrq:
	iret

; ── Entry point ──────────────────────────────────────────────────────────────
start:
	mov   r14, #1ff00			; stack pointer

	; Disable lcd_char overlay (move X off-screen)
	mov   r0, #1e0
	store (#c0000), r0

	; ── Clear back buffer to dark blue (0x0010) ──────────────────────────────
	mov   r0, #10
	store (#a001c), r0			; CLEAR_COLOR
	call  gpuWait
	mov   r0, #02
	store (#a0020), r0			; CMD = CLEAR_FB

	; ═══════════════════════════════════════════════════════════════════════════
	; Rectangle 1: RED  (50,30) to (200,100)
	; Triangle A: (50,30)-(200,30)-(200,100)
	; ═══════════════════════════════════════════════════════════════════════════
	call  gpuWait
	mov   r0, #32				; V0_X = 50
	store (#a0000), r0
	mov   r0, #1e				; V0_Y = 30
	store (#a0004), r0
	mov   r0, #c8				; V1_X = 200
	store (#a0008), r0
	mov   r0, #1e				; V1_Y = 30
	store (#a000c), r0
	mov   r0, #c8				; V2_X = 200
	store (#a0010), r0
	mov   r0, #64				; V2_Y = 100
	store (#a0014), r0
	mov   r0, #f800				; RED
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; Triangle B: (50,30)-(200,100)-(50,100)
	call  gpuWait
	mov   r0, #32				; V0_X = 50
	store (#a0000), r0
	mov   r0, #1e				; V0_Y = 30
	store (#a0004), r0
	mov   r0, #c8				; V1_X = 200
	store (#a0008), r0
	mov   r0, #64				; V1_Y = 100
	store (#a000c), r0
	mov   r0, #32				; V2_X = 50
	store (#a0010), r0
	mov   r0, #64				; V2_Y = 100
	store (#a0014), r0
	mov   r0, #f800				; RED
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ═══════════════════════════════════════════════════════════════════════════
	; Rectangle 2: GREEN  (220,30) to (430,100)
	; Triangle A: (220,30)-(430,30)-(430,100)
	; ═══════════════════════════════════════════════════════════════════════════
	call  gpuWait
	mov   r0, #dc				; V0_X = 220
	store (#a0000), r0
	mov   r0, #1e				; V0_Y = 30
	store (#a0004), r0
	mov   r0, #1ae				; V1_X = 430
	store (#a0008), r0
	mov   r0, #1e				; V1_Y = 30
	store (#a000c), r0
	mov   r0, #1ae				; V2_X = 430
	store (#a0010), r0
	mov   r0, #64				; V2_Y = 100
	store (#a0014), r0
	mov   r0, #7e0				; GREEN
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; Triangle B: (220,30)-(430,100)-(220,100)
	call  gpuWait
	mov   r0, #dc				; V0_X = 220
	store (#a0000), r0
	mov   r0, #1e				; V0_Y = 30
	store (#a0004), r0
	mov   r0, #1ae				; V1_X = 430
	store (#a0008), r0
	mov   r0, #64				; V1_Y = 100
	store (#a000c), r0
	mov   r0, #dc				; V2_X = 220
	store (#a0010), r0
	mov   r0, #64				; V2_Y = 100
	store (#a0014), r0
	mov   r0, #7e0				; GREEN
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ═══════════════════════════════════════════════════════════════════════════
	; Rectangle 3: YELLOW  (100,140) to (380,230)
	; Triangle A: (100,140)-(380,140)-(380,230)
	; ═══════════════════════════════════════════════════════════════════════════
	call  gpuWait
	mov   r0, #64				; V0_X = 100
	store (#a0000), r0
	mov   r0, #8c				; V0_Y = 140
	store (#a0004), r0
	mov   r0, #17c				; V1_X = 380
	store (#a0008), r0
	mov   r0, #8c				; V1_Y = 140
	store (#a000c), r0
	mov   r0, #17c				; V2_X = 380
	store (#a0010), r0
	mov   r0, #e6				; V2_Y = 230
	store (#a0014), r0
	mov   r0, #ffe0				; YELLOW
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; Triangle B: (100,140)-(380,230)-(100,230)
	call  gpuWait
	mov   r0, #64				; V0_X = 100
	store (#a0000), r0
	mov   r0, #8c				; V0_Y = 140
	store (#a0004), r0
	mov   r0, #17c				; V1_X = 380
	store (#a0008), r0
	mov   r0, #e6				; V1_Y = 230
	store (#a000c), r0
	mov   r0, #64				; V2_X = 100
	store (#a0010), r0
	mov   r0, #e6				; V2_Y = 230
	store (#a0014), r0
	mov   r0, #ffe0				; YELLOW
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ═══════════════════════════════════════════════════════════════════════════
	; Diagonal line 1: WHITE from (10,10) to (470,260)
	; Thin triangle: (10,10)-(470,260)-(470,258)  (2px wide at bottom)
	; ═══════════════════════════════════════════════════════════════════════════
	call  gpuWait
	mov   r0, #0a				; V0_X = 10
	store (#a0000), r0
	mov   r0, #0a				; V0_Y = 10
	store (#a0004), r0
	mov   r0, #1d6				; V1_X = 470
	store (#a0008), r0
	mov   r0, #104				; V1_Y = 260
	store (#a000c), r0
	mov   r0, #1d6				; V2_X = 470
	store (#a0010), r0
	mov   r0, #102				; V2_Y = 258
	store (#a0014), r0
	mov   r0, #ffff				; WHITE
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ═══════════════════════════════════════════════════════════════════════════
	; Diagonal line 2: CYAN from (470,10) to (10,260)
	; Thin triangle: (470,10)-(10,260)-(10,258)
	; ═══════════════════════════════════════════════════════════════════════════
	call  gpuWait
	mov   r0, #1d6				; V0_X = 470
	store (#a0000), r0
	mov   r0, #0a				; V0_Y = 10
	store (#a0004), r0
	mov   r0, #0a				; V1_X = 10
	store (#a0008), r0
	mov   r0, #104				; V1_Y = 260
	store (#a000c), r0
	mov   r0, #0a				; V2_X = 10
	store (#a0010), r0
	mov   r0, #102				; V2_Y = 258
	store (#a0014), r0
	mov   r0, #7ff				; CYAN
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ═══════════════════════════════════════════════════════════════════════════
	; Swap buffers to show the frame
	; ═══════════════════════════════════════════════════════════════════════════
	call  gpuWait
	mov   r0, #03
	store (#a0020), r0			; CMD = SWAP_BUFFERS

	; LED1 on to indicate test completed successfully
	mov   r0, #01
	store (#f0000), r0

	; ── Halt ─────────────────────────────────────────────────────────────────
halt:
	jmp   halt

; ── gpuWait: spin until STATUS.BUSY = 0 ──────────────────────────────────────
gpuWait:
	load  r1, (#a0024)
	and   r1, #01
	jnz   gpuWait
	ret
