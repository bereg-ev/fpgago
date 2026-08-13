/*
 * c64_easyflash.v — EasyFlash cartridge memory backend.
 *
 * The 1 MiB cart image lives in the v2 board's QSPI PSRAM (APS6404L) at
 * offset 0, laid out flat:  byte = {chip, bank[5:0], offset[12:0]}
 * (chip 0 = ROML, chip 1 = ROMH — the EasyFlash "two 512 KiB flash chips").
 * The soc does ALL the PLA/banking work; this module is only the memory:
 *
 *  · CPU reads through a 16-byte read LINE BUFFER (flip-flops, zero EBR —
 *    the c64 build has ~3 EBR left, so a BRAM cache is not an
 *    option — and is not needed at 1 MHz).
 *    A hit answers in 1 clk; a miss bursts 4 words and stalls the CPU via
 *    `busy` (the soc gates cpu_rdy — same effect as a VIC badline stall).
 *  · A push port for the QSPI ROM loader (qspi_slave banks 3..6 = four
 *    256 KiB chunks of the flat image) behind a 16-deep FIFO with an
 *    overflow counter: count drops,
 *    never assume the byte rate.
 *  · Am29F040 flash-command emulation, per chip: EAPI (the flash driver
 *    embedded in saving carts — Prince of Persia saves games with it)
 *    talks the real chip protocol.  Unlock $AA@$555/$55@$2AA, then:
 *      $90 autoselect (mfr $01 / dev $A4, exit on $F0)
 *      $A0 byte program (one PSRAM write; the CPU is stalled the ~20 clks
 *          it takes, so polling always sees it done)
 *      $80..$30 64 KiB sector erase: a background fill of $FF at ~20 clks
 *          per byte (~2.6 ms/sector — real flash takes far longer and EAPI
 *          polls).  While erasing, reads of that chip return toggle-bit
 *          status (bit6 flips per read, bit7 = 0 ≠ erased data); reads of
 *          the OTHER chip are serviced between fill bytes.
 *
 * Address match for the unlock cycles is on offs[10:0] only (the A0-A10
 * the real chip decodes); the bank register does not matter — exactly the
 * wiring EAPI assumes.
 *
 * Fidelity cut: byte program WRITES the byte instead of ANDing it into
 * the previous content (real flash can only clear bits).  EAPI always
 * programs freshly-erased bytes, so nothing observes the difference.
 */

module c64_easyflash(
    input  wire        clk,
    input  wire        rst,          // active-low, async (soc idiom)

    // CPU access, strobed at the soc's cpu_rdy tick (one per phi cycle)
    input  wire        rd_stb,
    input  wire        wr_stb,
    input  wire        chip,         // 0 = ROML window, 1 = ROMH window
    input  wire [5:0]  bank,         // live $DE00 bank register
    input  wire [12:0] offs,         // cpu_addr[12:0]
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata,
    output reg         rvalid,       // 1-clk: rdata is the answer to rd_stb
    output wire        busy,         // access in flight — soc gates cpu_rdy

    // QSPI ROM-loader push port (flat-image byte writes, machine frozen)
    input  wire        push_we,
    input  wire [19:0] push_addr,
    input  wire [7:0]  push_data,
    // dropped pushes (diag; must stay 0) — read by the P dump on hardware and
    // by check-efpush in sim, which is why it is public_flat_rd here
    output reg  [7:0]  push_ovr /* verilator public_flat_rd */,

    // ── PSRAM command port (the psram.v / psram_fast.v contract) ───────
    // The engine itself lives in the soc, NOT here.  With the fabric 1541
    // in the same bitstream there is exactly one APS6404L and one engine,
    // and psram_hub.v shares it: the drive has absolute priority (its phi
    // is stretchable but its deadlines are real), a cart line fill waits
    // behind at most one drive access.  That extra wait costs nothing new —
    // an EasyFlash miss already stalls the CPU through `busy`/ef_hold, the
    // same mechanism as a VIC badline.
    output reg  [23:0] ps_addr,
    output reg         ps_rd,          // 1-clk request pulses
    output reg         ps_wr,
    output reg         ps_byte,
    output reg  [3:0]  ps_words,
    output wire [31:0] ps_wdata_o,
    input  wire [31:0] ps_rdata,
    input  wire        ps_rdy,
    input  wire        ps_word_rdy,
    input  wire [2:0]  ps_word_idx,
    input  wire        ps_busy
);

    reg  [7:0]  ps_wdata;               // only byte writes are ever issued
    assign ps_wdata_o = {24'b0, ps_wdata};

    /* ── read line buffer: 16 bytes, one line, no tags array ─────────── */
    reg [7:0]  line [0:15];
    reg [15:0] line_tag;        // {chip, bank[5:0], offs[12:4]}
    reg        line_valid;
    reg [15:0] fill_tag;

    /* ── latched CPU request ─────────────────────────────────────────── */
    reg        req_rd;
    reg        r_chip;
    reg [5:0]  r_bank;
    reg [12:0] r_offs;
    wire [15:0] rd_tag  = {chip, bank, offs[12:4]};
    wire [19:0] rd_flat = {chip, bank, offs};

    /* ── flash command FSMs (one per chip) ───────────────────────────── */
    localparam F_IDLE = 3'd0, F_U1 = 3'd1, F_U2 = 3'd2,
               F_AUTOSEL = 3'd3, F_E1 = 3'd4, F_E2 = 3'd5, F_E3 = 3'd6,
               F_PROG = 3'd7;
    reg [2:0]  fst [0:1];
    reg        tgl;             // toggle bit (DQ6), flips per status read
    reg        prog_pend;
    reg [19:0] pw_addr;
    reg [7:0]  pw_data;

    reg        erase_active;
    reg        erase_chip;
    reg [2:0]  erase_sector;    // 64 KiB sector = bank[5:3]
    reg [15:0] erase_cnt;

    wire [10:0] a11 = offs[10:0];

    /* A read that must be answered with STATUS instead of memory:
     * autoselect mode, or the chip is mid-erase.  (A pending byte program
     * stalls the CPU outright, so it needs no status path.) */
    wire rd_is_status = (fst[chip] == F_AUTOSEL) ||
                        (erase_active && (erase_chip == chip));
    wire [7:0] status_byte =
        (fst[chip] == F_AUTOSEL)
            ? ((offs[1:0] == 2'd0) ? 8'h01 :        // manufacturer: AMD
               (offs[1:0] == 2'd1) ? 8'hA4 :        // device: Am29F040
                                     8'h00)         // sector protect: off
            : {1'b0, tgl, 6'b000000};               // erase toggle status

    /* ── push FIFO (16 deep) ─────────────────────────────────────────── */
    reg [27:0] pf [0:15];       // {addr[19:0], data[7:0]}
    /* Push FIFO occupancy is DERIVED from the two pointers, never held in a
     * register of its own.  It used to be a `pf_cnt` reg incremented by the
     * enqueue and decremented by the dequeue — two `pf_cnt <=` statements in
     * ONE always block.  The moment a push landed on the same clock as a
     * drain (which is most pushes once the master is quick), the second
     * assignment won, the count drifted down, wrapped past zero and the
     * writer started draining entries that had never been written: the cart
     * image came out corrupt while `push_ovr` still read 0, because by its
     * own accounting the FIFO never overflowed.  Board-reported 2026-08-06
     * as "cart accepted, blank screen"; measured in sim by pushing at 0.49
     * MB/s instead of the 0.25 MB/s the checks used to run at.
     * A wrap bit on each pointer makes full and empty distinguishable and
     * leaves each register with exactly one writer — which is what
     * the other machines' push FIFOs do,
     * and what this copy lost on the way over. */
    reg [4:0]  pf_wp, pf_rp;              // 4-bit index + 1 wrap bit
    wire [4:0] pf_cnt = pf_wp - pf_rp;    // 0..16

    /* ── arbiter ─────────────────────────────────────────────────────── */
    localparam S_IDLE = 3'd0, S_FILL = 3'd1, S_BYTE_RD = 3'd2,
               S_WRITE = 3'd3, S_ERASEW = 3'd4, S_PUSHW = 3'd5;
    reg [2:0] st;

    /* CPU must stall until an accepted access has answered; rvalid and the
     * soc's one-clk commit stage are covered by the soc's own gate term. */
    assign busy = req_rd || prog_pend ||
                  (st == S_FILL) || (st == S_BYTE_RD) || (st == S_WRITE);

    /* which line byte a burst word carries (the
     * engine shifts MSB-first so rdata[31:24] is the LOWEST address) */
    wire [3:0] wbase = {ps_word_idx[1:0], 2'b00};

    /* power-up values mirror the async-reset values (ecp5-rst-constfold) */
    initial begin
        rdata = 8'hFF; rvalid = 0; push_ovr = 0;
        ps_addr = 0; ps_rd = 0; ps_wr = 0; ps_byte = 1; ps_words = 4'd1;
        ps_wdata = 8'hFF;
        line_valid = 0; line_tag = 0; fill_tag = 0;
        req_rd = 0; r_chip = 0; r_bank = 0; r_offs = 0;
        fst[0] = F_IDLE; fst[1] = F_IDLE; tgl = 0;
        prog_pend = 0; pw_addr = 0; pw_data = 8'hFF;
        erase_active = 0; erase_chip = 0; erase_sector = 0; erase_cnt = 0;
        pf_wp = 0; pf_rp = 0;
        st = S_IDLE;
    end

    integer li;
    initial for (li = 0; li < 16; li = li + 1) line[li] = 8'hFF;

    always @(posedge clk or negedge rst) begin
        if (!rst) begin
            rdata <= 8'hFF; rvalid <= 0; push_ovr <= 0;
            ps_addr <= 0; ps_rd <= 0; ps_wr <= 0; ps_byte <= 1;
            ps_words <= 4'd1; ps_wdata <= 8'hFF;
            line_valid <= 0; line_tag <= 0; fill_tag <= 0;
            req_rd <= 0; r_chip <= 0; r_bank <= 0; r_offs <= 0;
            fst[0] <= F_IDLE; fst[1] <= F_IDLE; tgl <= 0;
            prog_pend <= 0; pw_addr <= 0; pw_data <= 8'hFF;
            erase_active <= 0; erase_chip <= 0; erase_sector <= 0;
            erase_cnt <= 0;
            pf_wp <= 0; pf_rp <= 0;
            st <= S_IDLE;
        end else begin
            rvalid <= 1'b0;
            ps_rd  <= 1'b0;     // engine request lines are 1-clk pulses
            ps_wr  <= 1'b0;

            /* ── push enqueue (SPI byte rate, far below drain rate) ── */
            if (push_we) begin
                if (pf_cnt == 5'd16)
                    push_ovr <= push_ovr + 1'b1;
                else begin
                    pf[pf_wp[3:0]] <= {push_addr, push_data};
                    pf_wp <= pf_wp + 1'b1;   // the ONLY writer of pf_wp
                end
            end

            /* ── CPU read accept ── */
            if (rd_stb) begin
                r_chip <= chip; r_bank <= bank; r_offs <= offs;
                if (rd_is_status) begin
                    rdata  <= status_byte;
                    rvalid <= 1'b1;
                    tgl    <= ~tgl;
                end else if (line_valid && (rd_tag == line_tag) &&
                             !erase_active) begin
                    rdata  <= line[offs[3:0]];
                    rvalid <= 1'b1;
                end else
                    req_rd <= 1'b1;
            end

            /* ── CPU write accept → flash command FSM (per chip) ── */
            if (wr_stb) begin
                case (fst[chip])
                F_IDLE:
                    if ((a11 == 11'h555) && (wdata == 8'hAA))
                        fst[chip] <= F_U1;
                F_U1:
                    fst[chip] <= ((a11 == 11'h2AA) && (wdata == 8'h55))
                                 ? F_U2 : F_IDLE;
                F_U2:
                    if (a11 == 11'h555)
                        case (wdata)
                        8'hA0:   fst[chip] <= F_PROG;
                        8'h90:   fst[chip] <= F_AUTOSEL;
                        8'h80:   fst[chip] <= F_E1;
                        default: fst[chip] <= F_IDLE;
                        endcase
                    else
                        fst[chip] <= F_IDLE;
                F_AUTOSEL:
                    if (wdata == 8'hF0) fst[chip] <= F_IDLE;
                F_E1:
                    fst[chip] <= ((a11 == 11'h555) && (wdata == 8'hAA))
                                 ? F_E2 : F_IDLE;
                F_E2:
                    fst[chip] <= ((a11 == 11'h2AA) && (wdata == 8'h55))
                                 ? F_E3 : F_IDLE;
                F_E3: begin
                    if (wdata == 8'h30) begin       // sector erase
                        erase_active <= 1'b1;
                        erase_chip   <= chip;
                        erase_sector <= bank[5:3];
                        erase_cnt    <= 16'd0;
                        line_valid   <= 1'b0;
                    end
                    fst[chip] <= F_IDLE;
                end
                F_PROG: begin                       // this write = the data
                    prog_pend <= 1'b1;
                    pw_addr   <= {chip, bank, offs};
                    pw_data   <= wdata;
                    line_valid <= 1'b0;             // may land in the line
                    fst[chip] <= F_IDLE;
                end
                endcase
            end

            /* ── engine arbiter ── */
            case (st)
            S_IDLE: begin
                if (req_rd && !ps_busy) begin
                    if (erase_active) begin
                        /* other-chip read mid-erase: keep it a single byte,
                         * squeezed between fill writes */
                        ps_addr  <= {4'b0, r_chip, r_bank, r_offs};
                        ps_byte  <= 1'b1;
                        ps_words <= 4'd1;
                        ps_rd    <= 1'b1;
                        st       <= S_BYTE_RD;
                    end else begin
                        ps_addr  <= {4'b0, r_chip, r_bank, r_offs[12:4], 4'b0};
                        ps_byte  <= 1'b0;
                        ps_words <= 4'd4;           // 16-byte line
                        ps_rd    <= 1'b1;
                        fill_tag <= {r_chip, r_bank, r_offs[12:4]};
                        st       <= S_FILL;
                    end
                end else if (prog_pend && !ps_busy) begin
                    ps_addr  <= {4'b0, pw_addr};
                    ps_wdata <= pw_data;
                    ps_byte  <= 1'b1;
                    ps_words <= 4'd1;
                    ps_wr    <= 1'b1;
                    st       <= S_WRITE;
                end else if (erase_active && !ps_busy) begin
                    ps_addr  <= {4'b0, erase_chip, erase_sector, erase_cnt};
                    ps_wdata <= 8'hFF;
                    ps_byte  <= 1'b1;
                    ps_words <= 4'd1;
                    ps_wr    <= 1'b1;
                    st       <= S_ERASEW;
                end else if ((pf_cnt != 0) && !ps_busy) begin
                    ps_addr  <= {4'b0, pf[pf_rp[3:0]][27:8]};
                    ps_wdata <= pf[pf_rp[3:0]][7:0];
                    ps_byte  <= 1'b1;
                    ps_words <= 4'd1;
                    ps_wr    <= 1'b1;
                    pf_rp    <= pf_rp + 1'b1;   // the ONLY writer of pf_rp
                    line_valid <= 1'b0;
                    st       <= S_PUSHW;
                end
            end

            S_FILL: begin
                if (ps_word_rdy) begin
                    line[wbase + 4'd0] <= ps_rdata[31:24];
                    line[wbase + 4'd1] <= ps_rdata[23:16];
                    line[wbase + 4'd2] <= ps_rdata[15:8];
                    line[wbase + 4'd3] <= ps_rdata[7:0];
                    /* grab the requested byte as it streams past */
                    if (ps_word_idx[1:0] == r_offs[3:2])
                        case (r_offs[1:0])
                        2'd0: rdata <= ps_rdata[31:24];
                        2'd1: rdata <= ps_rdata[23:16];
                        2'd2: rdata <= ps_rdata[15:8];
                        2'd3: rdata <= ps_rdata[7:0];
                        endcase
                end
                if (ps_rdy) begin
                    line_tag   <= fill_tag;
                    line_valid <= 1'b1;
                    rvalid     <= 1'b1;
                    req_rd     <= 1'b0;
                    st         <= S_IDLE;
                end
            end

            S_BYTE_RD:
                if (ps_rdy) begin
                    rdata  <= ps_rdata[7:0];
                    rvalid <= 1'b1;
                    req_rd <= 1'b0;
                    st     <= S_IDLE;
                end

            S_WRITE:
                if (ps_rdy) begin
                    prog_pend <= 1'b0;
                    st        <= S_IDLE;
                end

            S_ERASEW:
                if (ps_rdy) begin
                    erase_cnt <= erase_cnt + 1'b1;
                    if (erase_cnt == 16'hFFFF)
                        erase_active <= 1'b0;
                    st <= S_IDLE;
                end

            S_PUSHW:
                if (ps_rdy)
                    st <= S_IDLE;

            default: st <= S_IDLE;
            endcase
        end
    end

endmodule
