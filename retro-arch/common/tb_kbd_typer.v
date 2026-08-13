//
// tb_kbd_typer.v — self-checking bench for kbd_typer.v + c64_kbd_map.v
//
// Covers the modifier path the BIOS on-screen keyboard depends on: C= and
// CTRL as keys of their own ($84/$8E) and as prefixes ($81/$82) that hold
// down a modifier across the NEXT key.  Each case checks the whole 64-bit
// matrix while the key is down, so a modifier that is missing, stuck, or
// leaks into the following key fails here.
//
//   iverilog -o /tmp/tb_kbd_typer kbd_typer.v ../c64/c64_kbd_map.v \
//            tb_kbd_typer.v && vvp /tmp/tb_kbd_typer
//
`timescale 1ns/1ps

module tb_kbd_typer;

    // 100 kHz: HOLD/GAP/LEAD are the real millisecond counts, just cheap
    localparam CLK_HZ = 100_000;

    // c64 matrix positions, index = row*8 + col
    localparam KEY_A     = 1*8 + 2;
    localparam KEY_B     = 3*8 + 4;
    localparam KEY_SHIFT = 1*8 + 7;
    localparam KEY_CBM   = 7*8 + 5;
    localparam KEY_CTRL  = 7*8 + 2;

    reg         clk = 0, rst = 0;
    reg  [7:0]  rx_data = 0;
    reg         rx_valid = 0;
    wire [7:0]  map_code;
    wire        map_valid, map_shift, map_cbm, map_ctrl, map_prefix;
    wire [5:0]  map_key;
    wire [63:0] matrix;
    integer     errors = 0;

    always #5 clk = ~clk;

    c64_kbd_map map0(
        .code(map_code), .valid(map_valid), .shift(map_shift),
        .cbm(map_cbm), .ctrl(map_ctrl), .prefix(map_prefix), .key(map_key)
    );

    kbd_typer #(.CLK_HZ(CLK_HZ)) dut(
        .clk(clk), .rst(rst),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .map_code(map_code), .map_valid(map_valid),
        .map_shift(map_shift), .map_cbm(map_cbm), .map_ctrl(map_ctrl),
        .map_prefix(map_prefix), .map_key(map_key),
        .shift_key({3'd1, 3'd7}),
        .cbm_key  ({3'd7, 3'd5}),
        .ctrl_key ({3'd7, 3'd2}),
        .matrix(matrix)
    );

    task send(input [7:0] b);
        begin
            @(posedge clk);
            rx_data  <= b;
            rx_valid <= 1'b1;
            @(posedge clk);
            rx_valid <= 1'b0;
        end
    endtask

    // Wait for the key bit to go down, then compare the WHOLE matrix: the
    // modifiers must already be held (they lead by LEAD_MS) and nothing else
    // may be pressed.  Then wait for the release.
    task expect_press(input [5:0] k, input [63:0] want, input [511:0] what);
        integer guard;
        begin
            guard = 0;
            while (!matrix[k] && guard < 200_000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (!matrix[k]) begin
                $display("  FAIL: %0s — key never pressed", what);
                errors = errors + 1;
            end else if (matrix !== want) begin
                $display("  FAIL: %0s — matrix %h, want %h", what, matrix, want);
                errors = errors + 1;
            end else
                $display("  ok: %0s", what);
            guard = 0;
            while (matrix != 0 && guard < 200_000) begin
                @(posedge clk);
                guard = guard + 1;
            end
        end
    endtask

    // Nothing may be pressed for a full key time (prefixes are invisible).
    task expect_idle(input [511:0] what);
        integer i;
        begin
            for (i = 0; i < 6000; i = i + 1) begin
                @(posedge clk);
                if (matrix != 0) begin
                    $display("  FAIL: %0s — matrix %h", what, matrix);
                    errors = errors + 1;
                    i = 6000;
                end
            end
            if (matrix == 0)
                $display("  ok: %0s", what);
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 1;
        repeat (4) @(posedge clk);

        // plain key: nothing else held (the pre-existing behaviour)
        send(8'h41);                                     // 'A'
        expect_press(KEY_A, 64'd1 << KEY_A, "A alone presses A alone");

        // the shifted-letter encoding still envelopes LSHIFT
        send(8'hC1);                                     // SHIFT+A
        expect_press(KEY_A, (64'd1 << KEY_A) | (64'd1 << KEY_SHIFT),
                     "$C1 holds LSHIFT with A");

        // the modifier keys on their own
        send(8'h84);
        expect_press(KEY_CBM, 64'd1 << KEY_CBM, "$84 presses C= on its own");
        send(8'h8E);
        expect_press(KEY_CTRL, 64'd1 << KEY_CTRL, "$8E presses CTRL on its own");

        // a prefix presses nothing by itself ...
        send(8'h81);
        expect_idle("$81 alone presses nothing");
        // ... it holds C= across the key that follows
        send(8'h41);
        expect_press(KEY_A, (64'd1 << KEY_A) | (64'd1 << KEY_CBM),
                     "$81 A = C=+A");

        // and it is consumed: the next key is unmodified
        send(8'h42);                                     // 'B'
        expect_press(KEY_B, 64'd1 << KEY_B, "the C= prefix does not linger");

        send(8'h82); send(8'h41);
        expect_press(KEY_A, (64'd1 << KEY_A) | (64'd1 << KEY_CTRL),
                     "$82 A = CTRL+A");

        // prefixes stack, and one can modify a modifier key
        send(8'h81); send(8'h80); send(8'h41);
        expect_press(KEY_A, (64'd1 << KEY_A) | (64'd1 << KEY_CBM) |
                            (64'd1 << KEY_SHIFT), "$81 $80 A = C=+SHIFT+A");
        send(8'h80); send(8'h84);
        expect_press(KEY_CBM, (64'd1 << KEY_CBM) | (64'd1 << KEY_SHIFT),
                     "$80 $84 = SHIFT+C= (charset toggle)");

        // same key twice still gets its release gap, prefix and all
        send(8'h41); send(8'h81); send(8'h41);
        expect_press(KEY_A, 64'd1 << KEY_A, "repeated A: first press plain");
        expect_press(KEY_A, (64'd1 << KEY_A) | (64'd1 << KEY_CBM),
                     "repeated A: second press keeps its C= prefix");

        $display("%0s (%0d failure%0s)", errors ? "TEST FAILED" : "ALL PASS",
                 errors, errors == 1 ? "" : "s");
        if (errors) $fatal(1);
        $finish;
    end

endmodule
