# fpgago
FPGAgo is game console built entirely from scratch — CPUs, GPU, assembler, C compiler backend, and games — all running on a single FPGA chip. 

Build and hack classic‑style games on a handheld FPGA board that’s fully open, from tools to cores. 
Learn Verilog HDL the fun way — no vendor lock‑in, no black boxes.

100% open‑source toolchain (Yosys, nextpnr, etc.) 
Designed for teaching: labs, examples, and full source on GitHub 
Handheld retro form factor with display, controls, audio 
Perfect for courses, makerspaces, and self‑taught learners
                    
The Hardware 

A compact board built around a Lattice ECP5-25K FPGA driving a 4.3" 480x272 color LCD, backed by dual SDRAM banks — one for code, one for a double-buffered GPU framebuffer. Serial I/O, I2S audio, and a custom bootloader round out the platform.                                                                                                                                 

  Two CPUs (for now), Two Philosophies  
  
  RISC1 — The Minimalist

  An 8-bit CPU that proves you don't need much to have fun. RISC1 is the console's "retro within retro" — a CPU simple enough to understand in an afternoon, powering a game you can play in a minute.

  - 16 registers, 18-bit instructions, 4-stage pipeline
  - Hardware call stack (8 levels deep)
  - Port-mapped I/O — no memory bus, no caches, no complexity
  - Drives a character-mode LCD overlay using an IBM 8x16 bitmap font
  - Custom assembler (gcasm)                                                                                                                                                                                           

  RISC2 — The Workhorse                                                                                                                                                                     

  A 32-bit CPU with a custom LLVM/Clang compiler backend — write games in C, compile them to a homebrew ISA, and run them on real FPGA hardware.
   
  - 16 registers, 32-bit instructions, 5-stage pipeline with interrupts
  - 24-bit address space with load/store architecture
  - Software multiply, divide, and shift libraries (no hardware ALU shortcuts — every cycle is earned)
  - Full 64-bit arithmetic runtime for when 32 bits isn't enough
  - Instruction cache over SDRAM for large programs
  - Custom assembler (gcasm) and a complete C toolchain from Clang source to ROM binary
  - In progress: GPU
  
  RISC2 is where the ambition lives. A from-scratch compiler backend targeting a from-scratch CPU, rendering through a from-scratch GPU, onto a from-scratch display pipeline.     
