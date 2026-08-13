//
// tb_bios_text.v — self-checking TB for the full-screen BIOS text renderer
//
// Fills ALL 2000 cells with a deterministic pattern, then golden-checks
// EVERY pixel of one 800x480 frame against a software model of the
// VGA-9-dot rendering (9 native font px + extension column: non-ASCII
// glyphs repeat column 8, ASCII gets background) and the 16→19 line
// vertical stretch (font rows 2, 7, 12 doubled; 2 blank lines top,
// 3 bottom).  Also checks:
//   1. DE covers exactly 800x480 pixels, in 480 line bursts of 800
//   2. hsync/vsync pulse counts match the parameters
//
// Run (from an ARCH dir so ../roms/bios_font.hex resolves, e.g. c16/sim-desktop):
//   iverilog -o /tmp/tb_bios_text.vvp ../../common/tb_bios_text.v ../../common/bios_text.v
//   vvp /tmp/tb_bios_text.vvp                     (use the oss-cad-suite vvp!)
// c64 sub-line variant:
//   iverilog -Ptb_bios_text.HT=1008 -o ... (same sources)
// Optional frame dump for eyeballing:  vvp ... +ppm=/tmp/bios_frame.ppm
//
`timescale 1ns / 1ps

module tb_bios_text;

    parameter HT = 912;         // override with -Ptb_bios_text.HT=1008 for c64
    parameter VT = 624;         // -Ptb_bios_text.VT=525 for the console socs
                                // (lcd_out 1056x525 timing)

    reg clk = 0;
    reg rst = 0;
    always #5 clk = ~clk;

    reg  [10:0] wr_addr = 0;
    reg  [15:0] wr_data = 0;
    reg         wr_en   = 0;

    wire hs, vs, de;
    wire [15:0] data;

    bios_text #(.HTOTAL(HT), .VTOTAL(VT)) dut(
        .clk(clk), .rst(rst),
        .wr_addr(wr_addr), .wr_data(wr_data), .wr_en(wr_en),
        .lcd_hsync(hs), .lcd_vsync(vs), .lcd_de(de), .lcd_data(data)
    );

    integer errors = 0;

    // font model for the check (same files the DUT loads)
    reg [8:0] font [0:4095];
    initial begin
        $readmemh("../roms/bios_font_lo.hex", font, 0, 2047);
        $readmemh("../roms/bios_font_hi.hex", font, 2048, 4095);
    end

    // the cell pattern written to the DUT (blink bit kept clear)
    function [15:0] pat_cell;
        input [31:0] idx;
        reg [6:0] a;
        reg [7:0] c;
        begin
            a = idx * 5 + 3;
            c = idx;
            pat_cell = {1'b0, a, c};
        end
    endfunction

    // VGA palette (mirror of the DUT)
    function [15:0] vga565;
        input [3:0] c;
        case (c)
            4'h0: vga565 = 16'h0000;  4'h1: vga565 = 16'h0015;
            4'h2: vga565 = 16'h0540;  4'h3: vga565 = 16'h0555;
            4'h4: vga565 = 16'hA800;  4'h5: vga565 = 16'hA815;
            4'h6: vga565 = 16'hAAA0;  4'h7: vga565 = 16'hAD55;
            4'h8: vga565 = 16'h52AA;  4'h9: vga565 = 16'h52BF;
            4'hA: vga565 = 16'h57EA;  4'hB: vga565 = 16'h57FF;
            4'hC: vga565 = 16'hFAAA;  4'hD: vga565 = 16'hFABF;
            4'hE: vga565 = 16'hFFEA;  4'hF: vga565 = 16'hFFFF;
        endcase
    endfunction

    // in-row screen line → font row (16→19 Bresenham)
    function [3:0] fontrow;
        input [31:0] l;
        case (l)
            0: fontrow = 0;   1: fontrow = 1;   2: fontrow = 2;
            3: fontrow = 2;   4: fontrow = 3;   5: fontrow = 4;
            6: fontrow = 5;   7: fontrow = 6;   8: fontrow = 7;
            9: fontrow = 7;  10: fontrow = 8;  11: fontrow = 9;
           12: fontrow = 10; 13: fontrow = 11; 14: fontrow = 12;
           15: fontrow = 12; 16: fontrow = 13; 17: fontrow = 14;
           18: fontrow = 15;
            default: fontrow = 0;
        endcase
    endfunction

    // golden pixel for screen (x, y)
    function [15:0] golden;
        input [31:0] x;
        input [31:0] y;
        integer trow, l, col, ci, ph;
        reg [15:0] c;
        reg [8:0] frow;
        reg bit_on, ext;
        begin
            if (y < 2 || y >= 2 + 25 * 19)
                golden = 16'h0000;
            else begin
                trow = (y - 2) / 19;
                l    = (y - 2) % 19;
                col  = x / 10;
                ph   = x % 10;
                ci   = trow * 80 + col;
                c    = pat_cell(ci);
                frow = font[{c[7:0], fontrow(l)}];
                // non-ASCII glyphs repeat column 8 into the 10th column
                ext  = c[7] | (~c[6] & ~c[5]);
                bit_on = (ph <= 8) ? frow[8 - ph] : (frow[0] & ext);
                golden = bit_on
                         ? vga565(c[11:8])            // fg
                         : vga565({1'b0, c[14:12]});  // bg
            end
        end
    endfunction

    // frame stats
    integer de_count, line_px, de_lines, vs_pulses;
    integer x, y, i;
    reg de_prev, hs_prev, vs_prev;

    // optional PPM dump (+ppm=<path>)
    reg [1023:0] ppm_path;
    integer ppm_f;
    reg [15:0] frame [0:799][0:479];

    initial begin
        de_count = 0; de_lines = 0; line_px = 0; vs_pulses = 0;
        x = 0; y = 0;
        de_prev = 0; hs_prev = 1; vs_prev = 1;
        ppm_f = 0;

        // reset
        rst = 0;
        repeat (10) @(negedge clk);
        rst = 1;

        // paint all 2000 cells, one write per clock (qspi-burst style)
        @(negedge clk);
        wr_en = 1;
        for (i = 0; i < 2000; i = i + 1) begin
            wr_addr = i[10:0];
            wr_data = pat_cell(i);
            @(negedge clk);
        end
        wr_en = 0;

        // let the current (partial) frame finish, then measure one full frame
        @(posedge vs);      // inside/after a vsync pulse
        wait (vs == 1);

        // measure across one full frame: start at the first DE after vsync
        begin : MEASURE
            for (i = 0; i < 2 * HT * VT + 200; i = i + 1) begin
                @(negedge clk);

                // track x/y from sync: hsync falling edge = end of line
                if (hs_prev && !hs) begin
                    if (line_px > 0) begin
                        if (line_px != 800) begin
                            $display("FAIL: line %0d has %0d DE px (want 800)", y, line_px);
                            errors = errors + 1;
                        end
                        de_lines = de_lines + 1;
                        y = y + 1;
                    end
                    line_px = 0;
                    x = 0;
                end
                if (vs_prev && !vs) begin
                    vs_pulses = vs_pulses + 1;
                    if (vs_pulses == 1)
                        disable MEASURE;   // one full frame measured
                    y = 0;
                end

                if (de) begin
                    if (x < 800 && y < 480) begin
                        frame[x][y] = data;
                        if (data !== golden(x, y)) begin
                            if (errors < 20)
                                $display("FAIL: px (%0d,%0d) = %04x want %04x",
                                         x, y, data, golden(x, y));
                            errors = errors + 1;
                        end
                    end
                    de_count = de_count + 1;
                    line_px  = line_px + 1;
                    x = x + 1;
                end

                de_prev = de; hs_prev = hs; vs_prev = vs;
            end
            $display("FAIL: frame did not complete");
            errors = errors + 1;
        end

        if (de_count != 800 * 480) begin
            $display("FAIL: DE pixel count %0d (want %0d)", de_count, 800 * 480);
            errors = errors + 1;
        end
        if (de_lines < 479 || de_lines > 480) begin
            $display("FAIL: DE line count %0d (want 480)", de_lines);
            errors = errors + 1;
        end

        if ($value$plusargs("ppm=%s", ppm_path)) begin
            ppm_f = $fopen(ppm_path, "w");
            $fwrite(ppm_f, "P3\n800 480\n255\n");
            for (y = 0; y < 480; y = y + 1)
                for (x = 0; x < 800; x = x + 1)
                    $fwrite(ppm_f, "%0d %0d %0d\n",
                            {frame[x][y][15:11], frame[x][y][13:11]},
                            {frame[x][y][10:5],  frame[x][y][6:5]},
                            {frame[x][y][4:0],   frame[x][y][2:0]});
            $fclose(ppm_f);
            $display("PPM frame dumped");
        end

        if (errors == 0)
            $display("PASS: bios_text full-screen frame golden-checked (HTOTAL=%0d)", HT);
        else
            $display("FAIL: %0d error(s) (HTOTAL=%0d)", errors, HT);
        $finish;
    end

endmodule
