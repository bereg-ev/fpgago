/*
 * pet_via.v — Minimal 6522 VIA for PET jiffy clock
 *
 * Implements Timer 1 (free-running mode) and the interrupt logic needed
 * for the PET KERNAL's 60 Hz jiffy clock IRQ.  All other VIA features
 * (Timer 2, shift register, ports A/B, handshake) return safe defaults.
 *
 * Register map ($E840-$E84F):
 *   0: ORB/IRB    4: T1C-L    8: T2C-L    C: PCR
 *   1: ORA/IRA    5: T1C-H    9: T2C-H    D: IFR
 *   2: DDRB       6: T1L-L    A: SR        E: IER
 *   3: DDRA       7: T1L-H    B: ACR       F: ORA (no handshake)
 */

module pet_via(
    input clk,
    input rst,
    input [3:0] addr,
    input [7:0] din,
    output reg [7:0] dout,
    input we,
    input rd,
    output irq,
    input cpu_clk_en        // active for 1 cycle per CPU clock (for timer tick)
);

    // Timer 1
    reg [15:0] t1_counter;
    reg [15:0] t1_latch;
    reg        t1_irq_flag;    // IFR bit 6
    reg        t1_irq_enable;  // IER bit 6
    reg        t1_running;

    // Timer 2 (stub — not used by PET KERNAL for basic operation)
    reg [15:0] t2_counter;
    reg        t2_irq_flag;
    reg        t2_irq_enable;

    // Other registers (stubs)
    reg [7:0] orb, ora, ddrb, ddra;
    reg [7:0] acr, pcr;

    // IRQ output (active high, accent accent accent accent accent)
    // IFR bit 7 is the composite: any (flag & enable) sets it
    wire ifr_composite = (t1_irq_flag & t1_irq_enable)
                       | (t2_irq_flag & t2_irq_enable);
    assign irq = ifr_composite;

    // IFR read value
    wire [7:0] ifr_read = {ifr_composite, t1_irq_flag, t2_irq_flag, 5'b00000};

    // IER read value
    wire [7:0] ier_read = {1'b1, t1_irq_enable, t2_irq_enable, 5'b00000};

    // ── Timer 1 countdown ────────────────────────────────────────────
    always @(posedge clk or negedge rst)
        if (!rst) begin
            t1_counter    <= 16'hFFFF;
            t1_latch      <= 16'hFFFF;
            t1_irq_flag   <= 0;
            t1_irq_enable <= 0;
            t1_running    <= 0;
            t2_counter    <= 16'hFFFF;
            t2_irq_flag   <= 0;
            t2_irq_enable <= 0;
            orb  <= 8'hFF;
            ora  <= 8'hFF;
            ddrb <= 8'h00;
            ddra <= 8'h00;
            acr  <= 8'h00;
            pcr  <= 8'h00;
        end else begin
            // Timer 1: count down on each CPU clock
            if (cpu_clk_en && t1_running) begin
                if (t1_counter == 16'h0000) begin
                    t1_irq_flag <= 1;
                    // In free-running mode (ACR[6]=1), reload from latch
                    // In one-shot mode (ACR[6]=0), also reload but stop
                    t1_counter <= t1_latch;
                    if (!acr[6])
                        t1_running <= 0;
                end else begin
                    t1_counter <= t1_counter - 1;
                end
            end

            // Timer 2: simple countdown (stub)
            if (cpu_clk_en) begin
                if (t2_counter == 16'h0000)
                    t2_irq_flag <= 1;
                else
                    t2_counter <= t2_counter - 1;
            end

            // Register writes
            if (we) begin
                case (addr)
                    4'h0: orb  <= din;
                    4'h1: ora  <= din;
                    4'h2: ddrb <= din;
                    4'h3: ddra <= din;
                    4'h4: begin                    // T1C-L (write to latch low)
                        t1_latch[7:0] <= din;
                    end
                    4'h5: begin                    // T1C-H (write starts timer)
                        t1_latch[15:8] <= din;
                        t1_counter <= {din, t1_latch[7:0]};
                        t1_irq_flag <= 0;          // clear T1 interrupt
                        t1_running <= 1;
                    end
                    4'h6: t1_latch[7:0]  <= din;   // T1L-L
                    4'h7: begin                    // T1L-H
                        t1_latch[15:8] <= din;
                        t1_irq_flag <= 0;          // clear T1 interrupt
                    end
                    4'h8: t2_counter[7:0]  <= din; // T2C-L (latch)
                    4'h9: begin                    // T2C-H (start)
                        t2_counter <= {din, t2_counter[7:0]};
                        t2_irq_flag <= 0;
                    end
                    4'hB: acr <= din;              // ACR
                    4'hC: pcr <= din;              // PCR
                    4'hD: begin                    // IFR — write 1 to clear
                        if (din[6]) t1_irq_flag <= 0;
                        if (din[5]) t2_irq_flag <= 0;
                    end
                    4'hE: begin                    // IER
                        if (din[7]) begin          // set bits
                            if (din[6]) t1_irq_enable <= 1;
                            if (din[5]) t2_irq_enable <= 1;
                        end else begin             // clear bits
                            if (din[6]) t1_irq_enable <= 0;
                            if (din[5]) t2_irq_enable <= 0;
                        end
                    end
                    4'hF: ora <= din;              // ORA (no handshake)
                endcase
            end

            // Reading T1C-L clears T1 interrupt flag
            if (rd && addr == 4'h4)
                t1_irq_flag <= 0;

            // Reading T2C-L clears T2 interrupt flag
            if (rd && addr == 4'h8)
                t2_irq_flag <= 0;
        end

    // ── Register reads ───────────────────────────────────────────────
    always @* begin
        case (addr)
            4'h0: dout = orb;
            4'h1: dout = ora;
            4'h2: dout = ddrb;
            4'h3: dout = ddra;
            4'h4: dout = t1_counter[7:0];
            4'h5: dout = t1_counter[15:8];
            4'h6: dout = t1_latch[7:0];
            4'h7: dout = t1_latch[15:8];
            4'h8: dout = t2_counter[7:0];
            4'h9: dout = t2_counter[15:8];
            4'hA: dout = 8'h00;          // SR (stub)
            4'hB: dout = acr;
            4'hC: dout = pcr;
            4'hD: dout = ifr_read;
            4'hE: dout = ier_read;
            4'hF: dout = ora;
        endcase
    end

endmodule
