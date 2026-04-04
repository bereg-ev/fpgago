; =====================================================
; Snake Game for RISC1 CPU + Character LCD
; =====================================================
; Screen: 32 x 16 characters (8x16 pixels each)
; Game grid: 30 x 28 cells (each char = 2 vertical cells)
; Play area: gx=0..29, gy=0..27
;
; Port map (write):
;   0x10  text addr low byte
;   0x11  text addr high byte [1:0]
;   0x12  write char + auto-increment addr
;   0x13  write char (no auto-increment)
;
; Port map (read):
;   0x10  read char at current text addr
;   0x18  timer tick (8-bit)
;   0x1A  random number (LFSR)
;   0x20  UART status (bit 0 = RX ready)
;   0x21  UART RX data
;
; Custom characters:
;   0x05 = upper half block    0x06 = lower half block
;   0x07 = full block
;   0x08 = top-left corner     0x09 = top-right corner
;   0x0A = bottom-left corner  0x0B = bottom-right corner
;   0x0C = horizontal double   0x0D = vertical double
;   0x0E = food (top half)     0x0F = food (bottom half)
;   0x10 = food top+snake bot   0x11 = snake top+food bot
;
; Shadow buffer: text addr 512..1023
;   Each byte: [7:4]=top cell state, [3:0]=bottom cell state
;   0=empty  1=right  2=left  3=up  4=down  5=food
;
; Registers:
;   r4  = head_x (0..29)   r5  = head_y (0..27)
;   r6  = tail_x            r7  = tail_y
;   r8  = direction (1=R 2=L 3=U 4=D)
;   r9  = score             r10 = last_tick
;   r13 = speed (ticks per move)
;   r0-r3, r11, r12, r14, r15 = scratch
; =====================================================

; ---- Entry point ----
start:
    mov r4, #0f             ; head_x = 15
    mov r5, #0e             ; head_y = 14
    mov r6, #0c             ; tail_x = 12
    mov r7, #0e             ; tail_y = 14
    mov r8, #01             ; direction = right
    mov r9, #00             ; score = 0
    mov r13, #0a            ; speed = 10

    call clearScreen
    call clearShadow
    call drawBorder
    call drawInitSnake
    call drawScore
    call placeFood
    in r10, (#18)           ; last_tick

; ---- Main game loop ----
gameLoop:
    in r0, (#18)            ; current tick
    sub r0, r10             ; elapsed
    cmp r0, r13
    jc gameLoop             ; wait

    in r10, (#18)           ; update last_tick
    call checkInput
    call moveSnake
    cmp r0, #01
    jz gameOver
    jmp gameLoop

; =====================================================
; setAddr: set text RAM address from screen (r0=x, r1=y)
;   addr = y*32 + x
;   Clobbers: r3
; =====================================================
setAddr:
    mov r3, r1
    and r3, #07
    rcl r3, r3
    rcl r3, r3
    rcl r3, r3
    rcl r3, r3
    rcl r3, r3
    or  r3, r0
    out (#10), r3
    mov r3, r1              ; carry=0
    rcr r3, r3
    rcr r3, r3
    rcr r3, r3
    and r3, #01
    out (#11), r3
    ret

; =====================================================
; putCharScr: write char r2 at screen (r0=x, r1=y)
;   Clobbers: r3
; =====================================================
putCharScr:
    call setAddr
    out (#13), r2
    ret

; =====================================================
; calcGameAddr: game coords -> RAM address
;   Input:  r0=gx, r1=gy
;   Output: r3=addr_lo, r15=addr_hi (0 or 1)
;   char_x = gx+1, char_y = gy/2+1
;   addr = char_y*32 + char_x
;   Preserves: r0, r1
;   Clobbers: r3, r15
; =====================================================
calcGameAddr:
    mov r3, r1              ; gy (carry=0)
    rcr r3, r3              ; gy >> 1
    add r3, #01             ; cy = gy/2 + 1
    mov r15, r3             ; cy (carry=0)
    rcr r15, r15
    rcr r15, r15
    rcr r15, r15
    and r15, #01            ; addr_hi = cy >> 3
    and r3, #07             ; cy & 7
    rcl r3, r3
    rcl r3, r3
    rcl r3, r3
    rcl r3, r3
    rcl r3, r3              ; (cy&7) << 5
    or r3, r0               ; + gx
    add r3, #01             ; + 1 (for char_x = gx+1)
    ret

; =====================================================
; getCell: read game cell state
;   Input:  r0=gx, r1=gy
;   Output: r0=state (0-5)
;   Clobbers: r0, r3, r14, r15
; =====================================================
getCell:
    call calcGameAddr       ; r3=addr_lo, r15=addr_hi
    add r15, #02            ; shadow offset (+512)
    out (#10), r3
    out (#11), r15
    mov r14, r1             ; save gy (also 1-cycle delay)
    in r3, (#10)            ; shadow byte
    and r14, #01            ; gy & 1
    cmp r14, #00
    jnz gcBot
    ; Top nibble
    mov r0, r3              ; carry=0
    rcr r0, r0
    rcr r0, r0
    rcr r0, r0
    rcr r0, r0
    and r0, #0f
    ret
gcBot:
    mov r0, r3
    and r0, #0f
    ret

; =====================================================
; setCell: write game cell state + update display
;   Input:  r0=gx, r1=gy, r2=state
;   Clobbers: r0, r1, r2, r3, r11, r12, r14, r15
; =====================================================
setCell:
    call calcGameAddr       ; r3=addr_lo, r15=addr_hi
    mov r11, r3             ; save addr_lo
    mov r12, r15            ; save addr_hi (display)

    ; Read shadow byte
    add r15, #02            ; shadow offset
    out (#10), r3
    out (#11), r15
    mov r14, r1             ; save gy (1-cycle delay)
    in r3, (#10)            ; shadow byte

    ; Modify correct nibble
    and r14, #01
    cmp r14, #00
    jnz scBot
    ; Top nibble: clear top, set new
    and r3, #0f             ; keep bottom
    mov r14, r2             ; state (carry=0)
    rcl r14, r14
    rcl r14, r14
    rcl r14, r14
    rcl r14, r14            ; state << 4
    or r3, r14
    jmp scWr
scBot:
    and r3, #f0             ; keep top
    or r3, r2               ; set bottom

scWr:
    ; Write back to shadow
    mov r14, r12
    add r14, #02            ; shadow addr_hi
    out (#10), r11
    out (#11), r14
    out (#13), r3           ; write shadow byte

    ; Compute display char from shadow byte (r3)
    mov r14, r3             ; save copy
    mov r15, r3             ; carry=0
    rcr r15, r15
    rcr r15, r15
    rcr r15, r15
    rcr r15, r15
    and r15, #0f            ; top_state in r15
    and r14, #0f            ; bottom_state in r14

    cmp r15, #00
    jz scTE                 ; top empty
    ; Top filled
    cmp r14, #00
    jz scTO                 ; top only
    ; Both filled — check food+snake combos
    cmp r15, #05
    jz scFTB                ; top=food, bottom=snake
    cmp r14, #05
    jz scTBF                ; top=snake, bottom=food
    mov r2, #07             ; both snake -> full block
    jmp scDP
scFTB:
    mov r2, #10             ; food top + snake bottom
    jmp scDP
scTBF:
    mov r2, #11             ; snake top + food bottom
    jmp scDP
scTO:
    cmp r15, #05
    jz scFT
    mov r2, #05             ; upper half block
    jmp scDP
scFT:
    mov r2, #0e             ; food top
    jmp scDP
scTE:
    cmp r14, #00
    jz scEE                 ; both empty
    cmp r14, #05
    jz scFB
    mov r2, #06             ; lower half block
    jmp scDP
scFB:
    mov r2, #0f             ; food bottom
    jmp scDP
scEE:
    mov r2, #20             ; space

scDP:
    ; Write display char
    out (#10), r11          ; display addr_lo
    out (#11), r12          ; display addr_hi
    out (#13), r2
    ret

; =====================================================
; clearScreen: fill 512 display cells with space
;   Clobbers: r0, r2, r14, r15
; =====================================================
clearScreen:
    mov r0, #00
    out (#10), r0
    out (#11), r0
    mov r14, #00            ; inner counter (256)
    mov r15, #02            ; outer (2 passes)
csLoop:
    mov r2, #20
    out (#12), r2
    sub r14, #01
    jnz csLoop
    sub r15, #01
    jnz csLoop
    ret

; =====================================================
; clearShadow: fill shadow buffer (addr 512-1023) with 0
;   Clobbers: r0, r2, r14, r15
; =====================================================
clearShadow:
    mov r0, #00
    out (#10), r0
    mov r0, #02
    out (#11), r0           ; addr = 512
    mov r14, #00
    mov r15, #02
cshLoop:
    mov r2, #00
    out (#12), r2
    sub r14, #01
    jnz cshLoop
    sub r15, #01
    jnz cshLoop
    ret

; =====================================================
; drawBorder: DOS double-line border (full screen)
;   Clobbers: r0, r1, r2, r3, r14
; =====================================================
drawBorder:
    ; Top row (screen row 0, addr 0x000)
    mov r0, #00
    out (#10), r0
    out (#11), r0
    mov r2, #08             ; top-left corner
    out (#12), r2
    mov r14, #1e            ; 30 chars
dbTM:
    mov r2, #0c             ; horizontal double
    out (#12), r2
    sub r14, #01
    jnz dbTM
    mov r2, #09             ; top-right corner
    out (#12), r2

    ; Bottom row (screen row 15, addr = 15*32 = 480 = 0x1E0)
    mov r0, #e0
    out (#10), r0
    mov r0, #01
    out (#11), r0
    mov r2, #0a             ; bottom-left corner
    out (#12), r2
    mov r14, #1e
dbBM:
    mov r2, #0c
    out (#12), r2
    sub r14, #01
    jnz dbBM
    mov r2, #0b             ; bottom-right corner
    out (#12), r2

    ; Side walls (rows 1..14)
    mov r1, #01
dbSide:
    mov r0, #00             ; left wall
    mov r2, #0d             ; vertical double
    call putCharScr
    mov r0, #1f             ; right wall (x=31)
    mov r2, #0d
    call putCharScr
    add r1, #01
    cmp r1, #0f             ; row 15?
    jnz dbSide
    ret

; =====================================================
; drawInitSnake: 4 segments at gy=14, gx=12..15
;   Clobbers: r0, r1, r2, r3, r11, r12, r14, r15
; =====================================================
drawInitSnake:
    mov r2, #01             ; direction = right

    mov r0, #0c             ; gx=12 (tail)
    mov r1, #0e             ; gy=14
    call setCell

    mov r0, #0d
    mov r1, #0e
    mov r2, #01
    call setCell

    mov r0, #0e
    mov r1, #0e
    mov r2, #01
    call setCell

    mov r0, #0f             ; gx=15 (head)
    mov r1, #0e
    mov r2, #01
    call setCell
    ret

; =====================================================
; drawScore: hex score at top border (row 0, col 13)
;   Clobbers: r0, r1, r2, r3
; =====================================================
drawScore:
    mov r0, #0d
    mov r1, #00
    call setAddr
    mov r2, #20             ; space
    out (#12), r2
    ; High nibble
    mov r2, r9              ; carry=0
    rcr r2, r2
    rcr r2, r2
    rcr r2, r2
    rcr r2, r2
    and r2, #0f
    call nibToAscii
    out (#12), r2
    ; Low nibble
    mov r2, r9
    and r2, #0f
    call nibToAscii
    out (#12), r2
    mov r2, #20
    out (#12), r2
    ret

nibToAscii:
    cmp r2, #0a
    jnc nibLet
    add r2, #30
    ret
nibLet:
    add r2, #37
    ret

; =====================================================
; placeFood: place food (state 5) at random empty cell
;   Clobbers: r0, r1, r2, r3, r11, r12, r14, r15
; =====================================================
placeFood:
    in r0, (#1a)            ; random x
    and r0, #1f             ; 0..31
    cmp r0, #1e             ; >= 30?
    jnc placeFood
    mov r11, r0             ; save gx

    in r0, (#1a)            ; random y
    and r0, #1f             ; 0..31
    cmp r0, #1c             ; >= 28?
    jnc placeFood
    mov r12, r0             ; save gy

    ; Check if cell is empty
    mov r0, r11
    mov r1, r12
    call getCell            ; r0 = state
    cmp r0, #00
    jnz placeFood           ; not empty, retry

    ; Place food
    mov r0, r11
    mov r1, r12
    mov r2, #05             ; food state
    call setCell
    ret

; =====================================================
; checkInput: read UART, update direction (WASD)
;   Clobbers: r0
; =====================================================
checkInput:
    in r0, (#20)            ; UART status
    and r0, #01
    cmp r0, #01
    jnz ciDone

    in r0, (#21)            ; read char

    cmp r0, #77             ; 'w'
    jz ciUp
    cmp r0, #57             ; 'W'
    jz ciUp
    cmp r0, #73             ; 's'
    jz ciDown
    cmp r0, #53             ; 'S'
    jz ciDown
    cmp r0, #61             ; 'a'
    jz ciLeft
    cmp r0, #41             ; 'A'
    jz ciLeft
    cmp r0, #64             ; 'd'
    jz ciRight
    cmp r0, #44             ; 'D'
    jz ciRight
    jmp ciDone

ciUp:
    cmp r8, #04             ; can't reverse from down
    jz ciDone
    mov r8, #03
    jmp ciDone
ciDown:
    cmp r8, #03
    jz ciDone
    mov r8, #04
    jmp ciDone
ciLeft:
    cmp r8, #01
    jz ciDone
    mov r8, #02
    jmp ciDone
ciRight:
    cmp r8, #02
    jz ciDone
    mov r8, #01
ciDone:
    ret

; =====================================================
; moveSnake: advance head, check collision, handle tail
;   Returns r0=1 if game over, r0=0 if ok
;   Clobbers: r0, r1, r2, r3, r11, r12, r14, r15
;   Temporarily uses r13 (speed restored before return)
; =====================================================
moveSnake:
    ; 1. Write direction at current head position
    mov r0, r4
    mov r1, r5
    mov r2, r8
    call setCell

    ; 2. Compute new head position
    mov r0, r4
    mov r1, r5
    cmp r8, #01
    jz msR
    cmp r8, #02
    jz msL
    cmp r8, #03
    jz msU
    ; down
    add r1, #01
    jmp msChk
msR:
    add r0, #01
    jmp msChk
msL:
    sub r0, #01
    jmp msChk
msU:
    sub r1, #01

msChk:
    ; 3. Check bounds (unsigned: out-of-range wraps to >= limit)
    cmp r0, #1e             ; gx >= 30?
    jnc msGO
    cmp r1, #1c             ; gy >= 28?
    jnc msGO

    ; Update head position
    mov r4, r0
    mov r5, r1

    ; 4. Check what's at new head cell
    call getCell            ; r0=state (r4,r5 preserved by getCell)
    cmp r0, #00
    jz msEmpty
    cmp r0, #05
    jz msFood
    ; Body collision -> game over
    jmp msGO

msFood:
    add r9, #01             ; score++
    call drawScore
    call placeFood
    ; Draw head at new position
    mov r0, r4
    mov r1, r5
    mov r2, r8
    call setCell
    mov r0, #00
    ret

msEmpty:
    ; Draw head at new position
    mov r0, r4
    mov r1, r5
    mov r2, r8
    call setCell

    ; Read direction at tail to know which way it goes
    mov r0, r6
    mov r1, r7
    call getCell            ; r0=tail direction
    mov r13, r0             ; save tail_dir (borrow r13/speed)

    ; Erase tail cell
    mov r0, r6
    mov r1, r7
    mov r2, #00             ; empty
    call setCell

    ; Advance tail based on saved direction
    cmp r13, #01
    jz msTR
    cmp r13, #02
    jz msTL
    cmp r13, #03
    jz msTU
    ; down
    add r7, #01
    jmp msDone
msTR:
    add r6, #01
    jmp msDone
msTL:
    sub r6, #01
    jmp msDone
msTU:
    sub r7, #01

msDone:
    mov r13, #0a            ; restore speed
    mov r0, #00
    ret

msGO:
    mov r0, #01
    ret

; =====================================================
; gameOver: display message and wait for restart
; =====================================================
gameOver:
    ; "GAME OVER" at screen row 7, col 11
    mov r0, #0b
    mov r1, #07
    call setAddr

    mov r2, #47             ; 'G'
    out (#12), r2
    mov r2, #41             ; 'A'
    out (#12), r2
    mov r2, #4d             ; 'M'
    out (#12), r2
    mov r2, #45             ; 'E'
    out (#12), r2
    mov r2, #20             ; ' '
    out (#12), r2
    mov r2, #4f             ; 'O'
    out (#12), r2
    mov r2, #56             ; 'V'
    out (#12), r2
    mov r2, #45             ; 'E'
    out (#12), r2
    mov r2, #52             ; 'R'
    out (#12), r2

goWait:
    in r0, (#20)
    and r0, #01
    cmp r0, #01
    jnz goWait
    in r0, (#21)            ; consume key
    jmp start
