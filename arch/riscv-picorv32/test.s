# RISC-V hand-assembled UART hello-world test.
# Writes "Hi!\n" to UART_TX (at 0x008000) then loops forever.
# Assembled by hand into rom.hex — see comments for each instruction.

.section .text
.global _start

_start:
    lui   t0, 0x8           # 000082B7  t0 (x5) = 0x00008000  (UART_TX addr)
    li    t1, 0x48          # 04800313  t1 (x6) = 'H'
    sb    t1, 0(t0)         # 00628023  *UART_TX = 'H'
    li    t1, 0x69          # 06900313  t1 = 'i'
    sb    t1, 0(t0)         # 00628023
    li    t1, 0x21          # 02100313  t1 = '!'
    sb    t1, 0(t0)         # 00628023
    li    t1, 0x0A          # 00A00313  t1 = '\n'
    sb    t1, 0(t0)         # 00628023
1:  j     1b                # 0000006F  infinite loop

# Notes on RV32I encoding (used to derive rom.hex):
#   lui rd, imm[31:12]            : imm<<12 | rd<<7 | 0x37
#   addi rd, rs1, imm[11:0]       : imm<<20 | rs1<<15 | 0<<12 | rd<<7 | 0x13
#   sb rs2, imm(rs1)              : imm[11:5]<<25 | rs2<<20 | rs1<<15 | 0<<12 | imm[4:0]<<7 | 0x23
#   jal rd, offset                : offset (J-encoded) | rd<<7 | 0x6F
