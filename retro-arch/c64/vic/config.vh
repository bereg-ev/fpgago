// config.vh — VIC-II Kawari configuration for Verilator simulation

`ifndef config_vh_
`define config_vh_

`define VERSION_MAJOR 8'd0
`define VERSION_MINOR 8'd8

// Simulator mode — uses simplified bus interface
`define SIMULATOR_BOARD 1

// Video output: we tap the native 4-bit pixel_color3 index directly
// (soc.v owns the RGB565 palette + framebuffer capture), so the Kawari
// VGA scan-doubler/RGB stage (NEED_RGB/GEN_RGB + hires_vga_sync +
// COLOR_REGS palette) stays out of the build.  Re-enable at FPGA
// bring-up if the panel path wants Kawari-generated syncs.
//`define NEED_RGB 1
//`define GEN_RGB 1

// Video RAM: 4K internal (standard VIC-II)
`define WITH_4K 1

// Chip model: 6567R8 (NTSC) or 6569R3 (PAL)
// NTSC for now
//`define CHIP6567R8 1

`endif
