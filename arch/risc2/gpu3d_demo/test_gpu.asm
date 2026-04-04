; test_gpu.asm — GPU3D smoke test for the risc2-video simulation
;
; Assemble with:
;   cd project/risc2-video
;   ../../asm-compiler/gcasm -crisc2 gpu3d_demo/test_gpu.asm
; Then rebuild and run the simulation:
;   cd sim-desktop && make run
;
; What it does:
;   Each frame:
;     1. GPU_CLEAR with a dark-blue background
;     2. Draws three flat-shaded triangles (red, green, blue)
;     3. GPU_SWAP to display the rendered frame
;   Colour of each triangle shifts by 1 each frame → colour cycling animation.
;
; All GPU registers (byte addresses, 20-bit, accessible via store/load immediate):
;   V0_X = 0x0A0000   V0_Y = 0x0A0004
;   V1_X = 0x0A0008   V1_Y = 0x0A000C
;   V2_X = 0x0A0010   V2_Y = 0x0A0014
;   TRI_COLOR   = 0x0A0018    CLEAR_COLOR = 0x0A001C
;   CMD         = 0x0A0020    STATUS      = 0x0A0024
;
; Commands:  1 = DRAW_TRI,  2 = CLEAR_FB,  3 = SWAP_BUFFERS
;
; Register allocation in main loop:
;   r8  = frame counter (used to cycle colours)
;   r9  = saved link register for the one nested-call depth we use
;   r14 = stack pointer (not used here, but set for safety)
;   r15 = link register (CALL writes here automatically)

; ── Reset / interrupt vectors (must be first in ROM) ──────────────────────────
reset:
	jmp   start
	jmp   timerIrq
	.dd   0, 0, 0, 0, 0, 0		; unused interrupt slots

timerIrq:
	iret

; ── Entry point ───────────────────────────────────────────────────────────────
start:
	; Set up stack pointer at top of data RAM (0x01FF00)
	mov   r14, #1ff00

	; Disable the lcd_char overlay by moving its X window off-screen.
	; lcd_char control reg 0 (X position) is at byte address 0x0C0000.
	; Setting X >= 480 makes in_window always false → char_active always 0.
	mov   r0, #1e0			; 480 — just past the right edge
	store (#c0000), r0

	; Initialise frame counter to a bright red (RGB565 0xF800) so the
	; first frame is immediately visible rather than near-black.
	mov   r8, #f800

	; Set a permanent CLEAR_COLOR = dark blue (RGB565 0x0008)
	mov   r0, #08
	store (#a001c), r0

; ── Main render loop ───────────────────────────────────────────────────────────
; Each pass draws three triangles and swaps buffers.
;
; Vertex layout (screen is 480x272):
;
;   Triangle 0 — top of screen, pointing down (apex at bottom centre)
;      V0 = (120, 10)   V1 = (360, 10)   V2 = (240, 140)
;
;   Triangle 1 — bottom-left, pointing up (apex at top)
;      V0 = ( 40, 260)  V1 = (200, 260)  V2 = (120, 130)
;
;   Triangle 2 — bottom-right, pointing up
;      V0 = (280, 260)  V1 = (440, 260)  V2 = (360, 130)
;
; Colours cycle using r8 so the scene animates:
;   tri0_colour = r8            (steps through reds → greens → blues → ...)
;   tri1_colour = r8 + 0x0800   (R+4 offset)
;   tri2_colour = r8 + 0x1000   (R+8 offset)

mainLoop:
	; ── 1. Clear back buffer ─────────────────────────────────────────────────
	call  gpuWait
	mov   r0, #02
	store (#a0020), r0			; CMD = CLEAR_FB

	; ── 2. Triangle 0 ────────────────────────────────────────────────────────
	call  gpuWait
	mov   r0, #78				; V0_X = 120
	store (#a0000), r0
	mov   r0, #0a				; V0_Y = 10
	store (#a0004), r0
	mov   r0, #168				; V1_X = 360
	store (#a0008), r0
	mov   r0, #0a				; V1_Y = 10
	store (#a000c), r0
	mov   r0, #f0				; V2_X = 240
	store (#a0010), r0
	mov   r0, #8c				; V2_Y = 140
	store (#a0014), r0
	mov   r0, r8				; colour = frame counter
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ── 3. Triangle 1 ────────────────────────────────────────────────────────
	call  gpuWait
	mov   r0, #28				; V0_X = 40
	store (#a0000), r0
	mov   r0, #104				; V0_Y = 260
	store (#a0004), r0
	mov   r0, #c8				; V1_X = 200
	store (#a0008), r0
	mov   r0, #104				; V1_Y = 260
	store (#a000c), r0
	mov   r0, #78				; V2_X = 120
	store (#a0010), r0
	mov   r0, #82				; V2_Y = 130
	store (#a0014), r0
	mov   r0, r8				; colour = frame counter + 0x0800
	add   r0, #800
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ── 4. Triangle 2 ────────────────────────────────────────────────────────
	call  gpuWait
	mov   r0, #118				; V0_X = 280
	store (#a0000), r0
	mov   r0, #104				; V0_Y = 260
	store (#a0004), r0
	mov   r0, #1b8				; V1_X = 440
	store (#a0008), r0
	mov   r0, #104				; V1_Y = 260
	store (#a000c), r0
	mov   r0, #168				; V2_X = 360
	store (#a0010), r0
	mov   r0, #82				; V2_Y = 130
	store (#a0014), r0
	mov   r0, r8				; colour = frame counter + 0x1000
	add   r0, #1000
	store (#a0018), r0
	mov   r0, #01
	store (#a0020), r0			; CMD = DRAW_TRI

	; ── 5. Swap buffers ───────────────────────────────────────────────────────
	call  gpuWait
	mov   r0, #03
	store (#a0020), r0			; CMD = SWAP_BUFFERS

	; ── 6. Advance frame counter (colour cycling) ─────────────────────────────
	add   r8, #01
	; Mask to 16-bit RGB565 range (optional; wrapping is fine too)
	and   r8, #ffff

	jmp   mainLoop

; ── gpuWait: spin until STATUS.BUSY = 0 ──────────────────────────────────────
; Clobbers r1 only.  r15 is used as LR (set by CALL, consumed by RET).
gpuWait:
	load  r1, (#a0024)			; read STATUS
	and   r1, #01
	jnz   gpuWait
	ret
