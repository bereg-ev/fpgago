// RISC2 Register Definitions
// 16 general-purpose 32-bit registers (R0-R15)
// R14 = SP (stack pointer, software convention)
// R15 = LR (link register, hardwired by CALL instruction)

class RISC2Reg<bits<4> num, string n, list<string> alt = []>
    : Register<n, alt> {
  field bits<4> Num = num;
  let Namespace = "RISC2";
  let HWEncoding{3-0} = num;
}

def R0  : RISC2Reg<0,  "r0">;
def R1  : RISC2Reg<1,  "r1">;
def R2  : RISC2Reg<2,  "r2">;
def R3  : RISC2Reg<3,  "r3">;
def R4  : RISC2Reg<4,  "r4">;
def R5  : RISC2Reg<5,  "r5">;
def R6  : RISC2Reg<6,  "r6">;
def R7  : RISC2Reg<7,  "r7">;
def R8  : RISC2Reg<8,  "r8">;
def R9  : RISC2Reg<9,  "r9">;
def R10 : RISC2Reg<10, "r10">;
def R11 : RISC2Reg<11, "r11">;
def R12 : RISC2Reg<12, "r12">;
def R13 : RISC2Reg<13, "r13">;
def R14 : RISC2Reg<14, "r14", ["sp"]>;
def R15 : RISC2Reg<15, "r15", ["lr"]>;

// All general-purpose registers
def GPR : RegisterClass<"RISC2", [i32], 32,
    (add R0, R1, R2, R3, R4, R5, R6, R7,
         R8, R9, R10, R11, R12, R13, R14, R15)>;

// CPU flags register (C, Z, N, V — not directly accessible by software).
// Used by LLVM to track data dependencies between flag-setting instructions
// (CMP, ADD, SUB, AND, OR, XOR, RCL, RCR) and flag-reading branches
// (JZ, JNZ, JC, JNC, JGE, JLT).  This prevents the scheduler from
// inserting flag-clobbering ALU ops between a CMP and its branch.
def FLAGS : Register<"flags"> {
  let Namespace = "RISC2";
}
def FLG : RegisterClass<"RISC2", [i32], 32, (add FLAGS)> {
  let isAllocatable = 0;
}
