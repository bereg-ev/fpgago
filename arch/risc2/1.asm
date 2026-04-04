
reset:
	jmp start
	jmp timerInterrupt
	.dd 0, 0, 0, 0, 0, 0			; interrupt vector table

string-00:
	.db "Hello3 v9"

string-01:
	.db "Hello, world! v9"

timerInterrupt:
	iret

start:
	mov r0, #11
	mov r1, #10000
	store (r1), r0
	mov r0, #55aa
	load r0, (r1)
	nop
	nop

	mov r0, @string-00
	call printUart
	call newLine

	mov r0, @string-01
	mov r1, #21
	call printLcd

	; Narrow character window to 8 rows (128 px) so it stays in upper half
	mov r11, #0002	
	store (#c0000), r11	; X
	mov r11, #0002
	store (#c0001), r11	; Y
	mov r11, #0020	
	store (#c0002), r11	; chnumX
	mov r11, #8003
	store (#c0003), r11

	; Fill rows 136..271 with white (0xffff)
	mov r11, #ffff
	store (#d0001), r11			; fill_const = 0xffff
	mov r11, #00
	store (#d0002), r11			; w_col = 0
	mov r11, #1df
	store (#d0003), r11			; w_stop = 0x1df (479)
	
	mov r0, #88				; start row = 136
fillWhiteLoop:
	call fillSdramRow
	add r0, #01
	cmp r0, #110			
	jnz fillWhiteLoop

	; Fill rows 180..240 with blue (0x001f)
	mov r11, #1f
	store (#d0001), r11			; fill_const = 0x001f
	mov r11, #5a
	store (#d0002), r11			; w_col = 0x5a (90)
	mov r11, #12b
	store (#d0003), r11			; w_stop = 0x12b (299)
	mov r0, #b4				; start row = 180
fillBlueLoop:
	call fillSdramRow
	add r0, #01
	cmp r0, #f1
	jnz fillBlueLoop

	mov r1, #02
	store (#f0000), r1			; led 2

	; Copy SDRAM payload to X SDRAM and jump to it
	mov r0, #f0000
	add r0, #10000				; r0 = 0x100000 (SDRAM destination)
	mov r12, @sdramPayload			; ROM source address
	mov r5, #0c				; 12 words to copy
copyPayload:
	load r3, (r12)
	call writeWordToSdram
	add r0, #4
	add r12, #4
	sub r5, #1
	jnz copyPayload
	mov r15, #f0000
	add r15, #10000				; r15 = 0x100000
	ret					; jump to SDRAM code

fillSdramRow:

waitSdramWrite0:
	load r11, (#d0005)			; read rdy
	and r11, #01
	cmp r11, #01
	jnz waitSdramWrite0
	
	store (#d0000), r0			; w_row = r0
	mov r11, #01
	store (#d0004), r11			; trigger write burst
	nop
	nop
	nop
	ret
	
waitSdramWrite:
	load r11, (#d0005)			; read rdy
	and r11, #01
	cmp r11, #01
	jnz waitSdramWrite
	ret

writeWordToSdram:
	; Write r3 to SDRAM address r0 (must be in 0x100000–0x1FFFFF)
	; Clobbers: r9 (temp link), r11 (scratch). Preserves r0, r3, r5, r12.
	mov r9, r15
wws_waitIdle:
	load r11, (#f0010)
	and r11, #1
	jnz wws_waitIdle
	store (r0), r3
	nop
	nop
wws_waitDone:
	load r11, (#f0010)
	and r11, #1
	jnz wws_waitDone
	mov r15, r9
	ret

uartRx:
	mov r10, r15
	load r0, (#f0002)
	and r0, #01
	cmp r0, #01
	jnz uartRx9
	load r0, (#f0004)

	cmp r0, #31
	jz cmd1
	cmp r0, #32
	jz cmd2
	cmp r0, #33
	jz cmd3

	cmp r0, #34
	jz cmd4
	cmp r0, #35
	jz cmd5
	cmp r0, #36
	jz cmd6

	cmp r0, #78		; x
	jz cmdx
	cmp r0, #79		; y
	jz cmdy


uartRx9:
	mov r15, r10
	ret

cmd1:
	mov r1, #01
	store (#f0000), r1			; set led 2
	jmp uartRx9

cmd2:
	mov r1, #01
	store (#f0001), r1			; clr led 2
	jmp uartRx9

cmd3:
	mov r1, #03
	store (#01), r1
	mov r0, #34
	call uartTx
	jmp uartRx9

cmd4:
	mov r1, #03
	store (#f0001), r1			; clr led 2
	mov r1, #01				; sdram start_init
	store (r14), r1
	jmp uartRx9

cmd5:
	call waitForSdramReady
	mov r1, #02				; sdram start_read
	store (r14), r1

	call waitForSdramReady

	call dumpSdram
	jmp uartRx9

cmd6:
	jmp uartRx9

cmdx:
	mov r14, #f10e0		; sdram X selected
	jmp uartRx9

cmdy:
	mov r14, #f10f0		; sdram X selected
	jmp uartRx9

printUart:
	mov r3, r15
	mov r2, r0
print1:
	load.b r0, (r2)
	cmp r0, #0
	jz printEnd
	call uartTx
	add r2, #1
	jmp print1
printEnd:
	mov r15, r3
	ret

printLcd:
	mov r3, r15
	mov r2, r0
	add r1, #e0000
printLcd1:
	load.b r0, (r2)
	cmp r0, #0
	jz printLcdEnd
	store (r1), r0
	add r1, #1
	add r2, #1
	jmp printLcd1
printLcdEnd:
	mov r15, r3
	ret

uartTx:
	load r1, (#f0002)
	and r1, #04
	cmp r1, #04
	jz uartTx
	store (#f0003), r0
	ret

newLine:
	mov r8, r15
	mov r0, #0d
	call uartTx
	mov r0, #0a
	call uartTx
	mov r15, r8
	ret

hexOut:
	mov r6, r15
	mov r1, r0
	mov r2, r0
	rcr r1, r1
	rcr r1, r1
	rcr r1, r1
	rcr r1, r1
	call nibbleOut
	mov r1, r2
	and r1, #0f
	call nibbleOut
	mov r0, #20
	call uartTx
	mov r15, r6
	ret

nibbleOut:
	mov r7, r15
	cmp r1, #0a
	jc hex1
	sub r1, #0a
	add r1, #41
	jmp hex2
hex1:
	add r1, #30
hex2:
	mov r0, r1
	call uartTx
	mov r15, r7
	ret

waitForSdramReady:
	mov r13, r14
	add r13, #08
waitForSdramReady2:
	load r1, (r13)
	and r1, #01
	cmp r1, #01
	jnz waitForSdramReady2
	ret

dumpSdram:
	mov r9, r15
	mov r1, #08				; addr = 0
	store (r14), r1
	mov r5, #40
	mov r12, r14
	add r12, #09
	mov r13, r14
	add r13, #0a
dump1:
	load r0, (r13)			; data HI

	call hexOut
	load r0, (r12)			; data LO
	call hexOut
	mov r1, #10
	store (r14), r1			; increment buffer address
	mov r4, r5
	and r4, #07
	cmp r4, #07
	jnz dump2
	call newLine
dump2:
	sub r5, #01
	jnz dump1
	mov r15, r9
	ret

	nop
	nop
	nop

sdramPayload:
	; Animation that runs from SDRAM at 0x100000.
	; All jumps are PC-relative — correct after block-copy to SDRAM.
	mov r1, #01
	store (#f0000), r1			; LED1 on: SDRAM code is running
sdramAnimStart:
	mov r0, #39
sdramAnim1:
	mov r8, #e200
sdramWait:
	sub r8, #01
	jnz sdramWait
	store (#e0000), r0
	sub r0, #01
	cmp r0, #2f
	jz sdramAnimStart
	jmp sdramAnim1
	nop					; word 12 — padding
	nop
	nop
