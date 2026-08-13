//
// shot_cap.v — one-line screen capture for the USB screen-grab feature.
//
// Snoops the FINAL panel pixel stream (post BIOS/machine mux, so whatever
// is on the LCD is what gets captured), stores ONE requested line of the
// next frame into a single-EBR line buffer, and exposes it on a read port
// the QSPI slave streams to the MCU (SHOT_ARM/STATUS/READ commands).
//
// The MCU walks the frame line by line (~1-4 lines per panel frame, one
// grab is a couple of seconds) and relays each line to the desktop over
// the USB hostlink — see the board firmware's screen grab and desktop/app.
//
// Line indexing: visible (de) lines counted from the vsync pulse, 0..479
// on the 800x480 panels.  arm_dense=0 subsamples every 2nd pixel (400
// px/line, the panels show a 2x-doubled 400x240 logical frame); 1 stores
// all 800 px (needs two SHOT_READ sweeps > 1024 words? no: 800 words fit).
//
// arm_pair (subsampled only — two dense lines don't fit the EBR): one arm
// captures panel lines arm_line AND arm_line+2 (two consecutive LOGICAL
// lines on the 2x-doubled panel) in the same frame pass; the second line
// lands at word offset 512 (byte 1024 on the SHOT_READ port).  ready only
// rises once BOTH lines are in, halving the arm/poll/frame-wait count —
// the 2x grab speedup.  The two lines may be captured out of order (arm
// lands mid-frame between them): each is ticked off independently.
//
// Buffer: 1024 x 16 (one DP16KD).  Capture writes one port, the QSPI
// slave reads the other — never simultaneously on the same line by
// construction (ready gates the reads).
//
module shot_cap (
    input clk,
    input rst,                  // active-low async, same idiom as the socs

    // final LCD stream (1 px/clk while de; vs active low)
    input [15:0] px_data,
    input        px_de,
    input        px_vs,

    // control from qspi_slave
    input        arm_stb,       // 1-clk pulse: arm capture of arm_line
    input  [8:0] arm_line,      // panel line 0..479
    input        arm_dense,     // 1 = 800 px, 0 = every 2nd px (400)
    input        arm_pair,      // also capture arm_line+2 (ignored when dense)
    output reg   armed,
    output reg   ready,         // line captured, buffer valid

    // line-buffer read port (sync read, 1-clk latency)
    input  [9:0]  raddr,
    output reg [15:0] rdata
);

    reg [15:0] lbuf [0:1023];

    always @(posedge clk)
        rdata <= lbuf[raddr];

    // Write port lives in its own reset-free clocked block: a memory written
    // under an async reset cannot infer as EBR (yosys flattens it into 16k
    // registers and synthesis never finishes).  de_d is held 0 in reset, so
    // no spurious writes happen.
    wire       lb_we;
    wire [9:0] lb_waddr;

    always @(posedge clk)
        if (lb_we) lbuf[lb_waddr] <= px_data;

    // The socs' registered output stage delays the pixel DATA one clk
    // behind DE (m_data <= de_r ? ... : black), so time the capture off a
    // one-clk-delayed DE paired with the LIVE px_data — that pairing is
    // exactly aligned on the machine path (±1 px on the BIOS text path,
    // irrelevant for a screenshot).
    reg       de_d     = 0;     // de delayed to match the data pipeline
    reg       de_p     = 0;
    reg [8:0] line_cnt = 0;
    reg [9:0] x_cnt    = 0;
    reg       cap_now  = 0;     // this de-line is an armed one
    reg       sec_now  = 0;     // ...and it is the pair's SECOND line
    reg [8:0] line_q   = 0;
    reg       dense_q  = 0;
    reg       need0    = 0;     // pair bookkeeping: lines still to capture
    reg       need1    = 0;

    wire [8:0] line_q2 = line_q + 9'd2;    // pair partner (subsampled arms)
    wire match0 = need0 && (line_cnt == line_q);
    wire match1 = need1 && (line_cnt == line_q2);

    wire line_start = de_d && !de_p;
    wire line_end   = !de_d && de_p;
    wire cap_eff    = line_start ? (armed && (match0 || match1)) : cap_now;
    wire sec_eff    = line_start ? match1 : sec_now;
    wire [9:0] x_eff = line_start ? 10'd0 : x_cnt;

    // subsampled x/2 tops out at 399, so the sec bank bit at 512 never
    // collides; dense (800 words) never sets sec_eff
    assign lb_we    = de_d && cap_eff && (dense_q || !x_eff[0]);
    assign lb_waddr = dense_q ? x_eff : {sec_eff, x_eff[9:1]};

    always @(posedge clk or negedge rst)
        if (!rst) begin
            de_d     <= 0;
            de_p     <= 0;
            line_cnt <= 0;
            x_cnt    <= 0;
            cap_now  <= 0;
            sec_now  <= 0;
            armed    <= 0;
            ready    <= 0;
            line_q   <= 0;
            dense_q  <= 0;
            need0    <= 0;
            need1    <= 0;
        end else begin
            de_d <= px_de;
            de_p <= de_d;

            if (!px_vs) begin
                // vsync pulse (active low): restart the line counter
                line_cnt <= 0;
            end else if (line_start) begin
                x_cnt   <= 10'd1;      // pixel 0 is stored this clk
                cap_now <= cap_eff;
                sec_now <= sec_eff;
            end else if (line_end) begin
                line_cnt <= line_cnt + 1'b1;
                if (cap_now) begin
                    cap_now <= 0;
                    if (sec_now) need1 <= 0;
                    else         need0 <= 0;
                    // done once the OTHER line is no longer owed
                    if (sec_now ? !need0 : !need1) begin
                        armed <= 0;
                        ready <= 1;
                    end
                end
            end else if (de_d) begin
                x_cnt <= x_cnt + 1'b1;
            end

            // arm last: a re-arm racing a line end wins cleanly
            if (arm_stb) begin
                armed   <= 1;
                ready   <= 0;
                line_q  <= arm_line;
                dense_q <= arm_dense;
                need0   <= 1;
                need1   <= arm_pair && !arm_dense;
            end
        end

endmodule
