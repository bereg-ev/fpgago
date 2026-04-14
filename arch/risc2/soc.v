

`include "project.vh"

module soc(
    input clk,
    input rst,
    output led1,
    output led2,

    input rx,
    output tx,

    output i2s_en,
    output i2s_bclk,
    output i2s_lrck,
    output i2s_mclk,
    output i2s_data,

    output dbg1,
    output dbg2,

    output lcd_hsync,
    output lcd_vsync,
    output lcd_de,
    output reg [15:0] lcd_data,
    output lcd_pwm,
    output lcd_clk,

    output xclk,
    output xcke,
    output xcs,
    output xras,
    output xcas,
    output xwe,
    output [12:0] xa,
    inout  [15:0] xd,
    output [1:0] xba,
    output xldqm,
    output xudqm,

    output yclk,
    output ycke,
    output ycs,
    output yras,
    output ycas,
    output ywe,
    output [12:0] ya,
    inout  [15:0] yd,
    output [1:0] yba,
    output yldqm,
    output yudqm
    );

    wire [23:0] instr_addr;
    wire [23:0] data_addr;
    wire [31:0] instr_data, data_out_value, dataram_out;
    wire [3:0] data_out_strobe;
    wire data_rd, data_wr;

    wire [127:0] cpuDbg;

    wire boot_we, dbg_rst_req, boot_rst_req;

    reg sled1, sled2;

`ifdef CPU_DEBUGGER
    assign led1 = dbg_led ? 1'b1 : sled1;
 `else
    assign led1 = sled1;
`endif

    assign led2 = sled2;

    wire [7:0] icache_dbg;
    wire [7:0] dummy;
    wire xdbg1 = icache_dbg[7];
    wire xdbg2 = icache_dbg[6];
    assign dbg1 = xdbg1;
    assign dbg2 = xdbg2;

    wire [31:0] rom_out_value;

`ifdef SIMULATION
    dual_port_ram_4k_18 #(.HI_HALF(0)) romL (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[14:2]), .din_a(18'b0), .dout_a({dummy[1:0], instr_data[15:0]}),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[14:2]), .din_b(18'b0), .dout_b({dummy[3:2], rom_out_value[15:0]})
    );
    dual_port_ram_4k_18 #(.HI_HALF(1)) romH (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[14:2]), .din_a(18'b0), .dout_a({dummy[5:4], instr_data[31:16]}),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[14:2]), .din_b(18'b0), .dout_b({dummy[7:6], rom_out_value[31:16]})
    );
`else
  `ifdef EXTENDED_MEM
    /* Boot ROM: 3K words (12KB) across 3 banks of 1K words each */
    wire [17:0] romL0_iout, romH0_iout, romL0_dout, romH0_dout;
    wire [17:0] romL1_iout, romH1_iout, romL1_dout, romH1_dout;
    wire [17:0] romL2_iout, romH2_iout, romL2_dout, romH2_dout;

    dual_port_ram_1k_18 #(
`include "romL.vh"
        ) romL0 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL0_iout),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b(romL0_dout)
    );
    dual_port_ram_1k_18 #(
`include "romH.vh"
        ) romH0 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH0_iout),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b(romH0_dout)
    );

    dual_port_ram_1k_18 #(
`include "romL2.vh"
        ) romL1 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL1_iout),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b(romL1_dout)
    );
    dual_port_ram_1k_18 #(
`include "romH2.vh"
        ) romH1 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH1_iout),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b(romH1_dout)
    );

    dual_port_ram_1k_18 #(
`include "romL3.vh"
        ) romL2 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romL2_iout),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b(romL2_dout)
    );
    dual_port_ram_1k_18 #(
`include "romH3.vh"
        ) romH2 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a(romH2_iout),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b(romH2_dout)
    );

    reg [1:0] rom_ibank, rom_dbank;
    always @(posedge clk) begin
        rom_ibank <= instr_addr[13:12];
        rom_dbank <= data_addr[13:12];
    end

    assign instr_data = rom_ibank == 2'd2 ? {romH2_iout[15:0], romL2_iout[15:0]}
                      : rom_ibank == 2'd1 ? {romH1_iout[15:0], romL1_iout[15:0]}
                      :                     {romH0_iout[15:0], romL0_iout[15:0]};
    assign rom_out_value = rom_dbank == 2'd2 ? {romH2_dout[15:0], romL2_dout[15:0]}
                         : rom_dbank == 2'd1 ? {romH1_dout[15:0], romL1_dout[15:0]}
                         :                     {romH0_dout[15:0], romL0_dout[15:0]};
  `else
    /* Boot ROM: 1K words (4KB) */
    dual_port_ram_1k_18 #(
`include "romL.vh"
        ) romL (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a({dummy[1:0], instr_data[15:0]}),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b({dummy[3:2], rom_out_value[15:0]})
    );
    dual_port_ram_1k_18 #(
`include "romH.vh"
        ) romH (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(instr_addr[11:2]), .din_a(18'b0), .dout_a({dummy[5:4], instr_data[31:16]}),
        .clk_b(clk), .we_b(1'b0), .addr_b(data_addr[11:2]), .dout_b({dummy[7:6], rom_out_value[31:16]})
    );
  `endif
`endif

    /* Data RAM: 4 byte-lane BRAMs, write-enabled independently via
     * data_out_strobe[3:0] from the CPU. */
    wire [9:0] dummy_b0, dummy_b1, dummy_b2, dummy_b3;
    wire dataram_wr = data_wr & (data_addr[23:16] == 8'h01);

`ifdef EXTENDED_MEM
    /* 4K words per lane (16KB total) */
    ram_4k_18 dataram_b0 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b0, dataram_out[7:0]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[0]),
        .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[7:0]})
    );

    ram_4k_18 dataram_b1 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b1, dataram_out[15:8]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[1]),
        .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[15:8]})
    );

    ram_4k_18 dataram_b2 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b2, dataram_out[23:16]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[2]),
        .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[23:16]})
    );

    ram_4k_18 dataram_b3 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[13:2]), .din_a(18'b0), .dout_a({dummy_b3, dataram_out[31:24]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[3]),
        .addr_b(data_addr[13:2]), .din_b({10'b0, data_out_value[31:24]})
    );
`else
    /* 1K words per lane (4KB total) */
    ram_1k_18 dataram_b0 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[11:2]), .din_a(18'b0), .dout_a({dummy_b0, dataram_out[7:0]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[0]),
        .addr_b(data_addr[11:2]), .din_b({10'b0, data_out_value[7:0]})
    );

    ram_1k_18 dataram_b1 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[11:2]), .din_a(18'b0), .dout_a({dummy_b1, dataram_out[15:8]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[1]),
        .addr_b(data_addr[11:2]), .din_b({10'b0, data_out_value[15:8]})
    );

    ram_1k_18 dataram_b2 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[11:2]), .din_a(18'b0), .dout_a({dummy_b2, dataram_out[23:16]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[2]),
        .addr_b(data_addr[11:2]), .din_b({10'b0, data_out_value[23:16]})
    );

    ram_1k_18 dataram_b3 (
        .clk_a(clk), .we_a(1'b0),
        .addr_a(data_addr[11:2]), .din_a(18'b0), .dout_a({dummy_b3, dataram_out[31:24]}),
        .clk_b(clk), .we_b(dataram_wr & data_out_strobe[3]),
        .addr_b(data_addr[11:2]), .din_b({10'b0, data_out_value[31:24]})
    );
`endif

    reg [7:0] txdata;
    reg txen, rxrdy, rxen0, rxovf;
    wire txbusy, rxen, rxenA;
    wire [7:0] rxdata, rxdataA, dbg_txdata;

`ifdef CPU_DEBUGGER
    uart uart0(.clk(clk), .rst(rst), .tx(tx), .rx(rx), .txdata(txdata), .txen(txen), .txbusy(txbusy),
        .rxdata(rxdataA), .rxen(rxenA));
`else
    uart uart0(.clk(clk), .rst(rst), .tx(tx), .rx(rx), .txdata(txdata), .txen(txen), .txbusy(txbusy),
        .rxdata(rxdata), .rxen(rxen));
`endif

`ifdef CPU_DEBUGGER
    debugger debug0(.clk(clk), .rst(rst),
        .rxen_in(rxenA), .rxdata_in(rxdataA), .rxen_out(rxen), .rxdata_out(rxdata),
        .txen(dbg_txen), .txdata(dbg_txdata),
        .cpuDbg(cpuDbg[127:0]),
        .clk_en(cpu_clk_en), .cpu_rst_req(dbg_rst_req), .led(dbg_led)
        );
`endif

    wire [10:0] lcd_col, lcd_row;
    wire [15:0] char_pixel_out;
    wire        char_active;
    wire [15:0] sdram_pixel_out;

    lcd_out lcd0(.clk(clk), .rst(rst),
        .ctrl_addr(3'h0), .ctrl_data(11'h0), .ctrl_we(1'b0),
        .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .row(lcd_row), .col(lcd_col)
    );

    /* Hardware LCD char init — enable display after reset so text is visible
       even if software init (gpu_clear_black/lcd_init) hasn't run yet */
    reg [2:0] lcdi_cnt;
    reg [23:0] lcdi_addr;
    reg [15:0] lcdi_data;
    reg        lcdi_we;

    always @(posedge clk or negedge rst)
    if (!rst) begin
        lcdi_cnt <= 0;
        lcdi_we  <= 0;
    end else if (lcdi_cnt < 4) begin
        lcdi_cnt <= lcdi_cnt + 1;
        lcdi_we  <= 1;
        case (lcdi_cnt)
            0: begin lcdi_addr <= 24'h0C0000; lcdi_data <= 16'd112;   end  // X = 112
            1: begin lcdi_addr <= 24'h0C0001; lcdi_data <= 16'd0;     end  // Y = 0
            2: begin lcdi_addr <= 24'h0C0002; lcdi_data <= 16'd32;    end  // chnumx = 32
            3: begin lcdi_addr <= 24'h0C0003; lcdi_data <= 16'h8011;  end  // enabled=1, chnumy=17
        endcase
    end else
        lcdi_we <= 0;

    wire        lcd_we   = (lcdi_cnt < 4) ? lcdi_we : data_wr;
    wire [23:0] lcd_addr = (lcdi_cnt < 4) ? lcdi_addr : data_addr[23:0];
    wire [15:0] lcd_wdata = (lcdi_cnt < 4) ? lcdi_data : data_out_value[15:0];

    lcd_char lcdc0(.clk(clk), .rst(rst),
        .ctrl_addr(lcd_addr), .ctrl_data(lcd_wdata), .ctrl_we(lcd_we),
        .row(lcd_row), .col(lcd_col),
        .char_pixel_out(char_pixel_out), .char_active(char_active)
    );

    timer timer0(.clk(clk), .rst(rst),
        .timer_irq(timer_irq), .timer_irq_ack(timer_irq_ack)
    );

`ifdef CPU_DEBUGGER
    wire cpu_rst = rst & (~dbg_rst_req);
`else
    wire cpu_rst = rst;
`endif

//    wire cpu_rst = rst & (~boot_rst_req) & (~dbg_rst_req);

    reg [31:0] data_in_value;
    reg data_in_valid;

    wire [31:0] icache_instr;
    wire        icache_valid;
    wire        icache_wr_busy;

    /* X SDRAM address range: 0x100000–0x1FFFFF */
    wire sdram_data_range = (data_addr[23:20] == 4'h1);

    /* Data cache outputs */
    wire [31:0] icache_data_out;
    wire        icache_data_valid;
    wire        icache_data_wr_busy;

    /* Track pending SDRAM data read (survives across cycles until data_valid) */
    reg xdata_pending;
    always @(posedge clk or negedge cpu_rst)
        if (!cpu_rst) xdata_pending <= 0;
        else begin
            if (data_rd && sdram_data_range) xdata_pending <= 1;
            else if (icache_data_valid) xdata_pending <= 0;
        end

    cpu_risc2 cpu0(
        .clk(clk),

`ifdef CPU_DEBUGGER
        .clk_en(cpu_clk_en && !icache_data_wr_busy),
        .rst(cpu_rst),
`else
        .clk_en(!icache_data_wr_busy),
        .rst(rst),
`endif

//        .clk_en(1'b1),
//        .clk_en(rxen != rxen0 && rxdata == 8'h53),

        .instr_addr(instr_addr), .instr_value(icache_instr), .instr_valid(icache_valid),
        .data_addr(data_addr), .data_in_value(data_in_value), .data_in_valid(data_in_valid), .data_rd(data_rd),
        .data_out_value(data_out_value), .data_wr(data_wr), .data_out_strobe(data_out_strobe),
        .data_out_rdy(1'b1),
        .irq(timer_irq), .irq_num(3'h1), .irq_ack(timer_irq_ack),
        .cpuDbg(cpuDbg)
    );

    assign xclk = clk;

    icache icache0(
        .clk(clk), .rst(rst),
        .cpu_addr(instr_addr),
        .cpu_instr(icache_instr),
        .cpu_valid(icache_valid),
        .rom_data(instr_data),
        .wr_addr(24'b0),
        .wr_data(32'b0),
        .wr_en(1'b0),                  /* all writes via data_wr_en now */
        .wr_busy(icache_wr_busy),
        /* Data cache port */
        .data_addr(data_addr),
        .data_rd(data_rd && sdram_data_range),
        .data_wr_val(data_out_value),
        .data_wr_strobe(data_out_strobe),
        .data_wr_en(data_wr && sdram_data_range),
        .data_out(icache_data_out),
        .data_valid(icache_data_valid),
        .data_wr_busy(icache_data_wr_busy),
        /* X SDRAM bus */
        .sd_clk(),                                          // xclk driven above
        .sd_cke(xcke), .sd_cs(xcs), .sd_ras(xras), .sd_cas(xcas), .sd_we(xwe),
        .sd_a(xa), .sd_d(xd), .sd_ba(xba), .sd_ldqm(xldqm), .sd_udqm(xudqm),
        .dbg(icache_dbg)
    );

    /* Y SDRAM: memory-mapped framebuffer with write-combining cache */
    wire gpu_busy_raw;
    /* GPU watchdog: if dcache is stuck for 2M cycles (~100ms), report not busy
       so the CPU's gpu_wait() doesn't spin forever when Y SDRAM is unresponsive */
    reg [20:0] gpu_watchdog;
    wire gpu_busy = gpu_busy_raw & ~gpu_watchdog[20];
    always @(posedge clk or negedge rst)
        if (!rst)
            gpu_watchdog <= 0;
        else if (!gpu_busy_raw)
            gpu_watchdog <= 0;
        else if (!gpu_watchdog[20])
            gpu_watchdog <= gpu_watchdog + 1;

    dcache dcache0(
        .clk(clk), .rst(rst),
        .row(lcd_row), .col(lcd_col),
        .sdram_pixel_out(sdram_pixel_out),
        .ctrl_addr(data_addr[23:0]),
        .ctrl_data(data_out_value[15:0]),
        .ctrl_we(data_wr),
        .gpu_busy(gpu_busy_raw),
        .sd_cke(ycke), .sd_cs(ycs), .sd_ras(yras), .sd_cas(ycas), .sd_we(ywe),
        .sd_a(ya), .sd_d(yd), .sd_ba(yba), .sd_ldqm(yldqm), .sd_udqm(yudqm)
    );

    assign yclk = clk;  /* SDRAM clock output for Y bank */

    i2s i2s0(
        .clk(clk), .rst(rst),
        .en(i2s_en), .bclk(i2s_bclk), .lrck(i2s_lrck), .mclk(i2s_mclk), .data(i2s_data)
    );

    assign lcd_pwm = 1'b1;
    assign lcd_clk = clk;

    always @(posedge clk or negedge rst)
    if (!rst)
    begin
        lcd_data <= 0;
    end else
    begin
        if (lcd_de)
            /* char_active: character window overlay; else show SDRAM background */
            lcd_data <= char_active ? char_pixel_out : sdram_pixel_out;
    end

    reg dbg_txen0, data_rd2;

    always @(posedge clk or negedge cpu_rst)
    if (!cpu_rst)
    begin
        {sled1, sled2, txdata, txen, dbg_txen0} <= 0;
        {data_in_value, rxen0, rxrdy, rxovf, data_rd2, data_in_valid} <= 0;
    end else
    begin
        rxen0 <= rxen;
        data_rd2 <= data_rd;
`ifdef CPU_DEBUGGER
        dbg_txen0 <= dbg_txen;
`else
        dbg_txen0 <= 1'b0;
`endif

        /* data_in_valid: low during BRAM latency or SDRAM data read pending */
`ifdef SIMULATION
        data_in_valid <= (data_rd && (data_addr[23:15] == 9'b0 || data_addr[23:16] == 8'h01 || sdram_data_range)) ? 1'b0
                      : (xdata_pending ? 1'b0 : 1'b1);
`else
  `ifdef EXTENDED_MEM
        data_in_valid <= (data_rd && (data_addr[23:14] == 10'b0 || data_addr[23:16] == 8'h01 || sdram_data_range)) ? 1'b0
                      : (xdata_pending ? 1'b0 : 1'b1);
  `else
        data_in_valid <= (data_rd && (data_addr[23:12] == 12'b0 || data_addr[23:16] == 8'h01 || sdram_data_range)) ? 1'b0
                      : (xdata_pending ? 1'b0 : 1'b1);
  `endif
`endif

`ifdef SIMULATION
        if (data_rd2 && data_addr[23:15] == 9'b0)              // read boot memory (32KB)
`else
  `ifdef EXTENDED_MEM
        if (data_rd2 && data_addr[23:14] == 10'b0)             // read boot memory (12KB)
  `else
        if (data_rd2 && data_addr[23:12] == 12'b0)             // read boot memory (4KB)
  `endif
`endif
            data_in_value <= rom_out_value;

        if (data_wr && data_addr == 24'hf0000)              // set bit port
        begin
	        if (data_out_value[0])
                sled1 <= 1;

	        if (data_out_value[1])
                sled2 <= 1;
        end

        if (data_wr && data_addr == 24'hf0001)              // clear bit port
        begin
	        if (data_out_value[0])
                sled1 <= 0;

	        if (data_out_value[1])
                sled2 <= 0;
        end

        if (data_rd && data_addr == 24'hf0002)              // read bit port
            data_in_value <= {5'b10000, txbusy, rxovf, rxrdy};

        if (data_wr && data_addr == 24'hf0003)              // UART tx data port
        begin
            txdata <= data_out_value;
            txen <= ~txen;
        end
`ifdef CPU_DEBUGGER
        else if (dbg_txen != dbg_txen0)
        begin
            txdata <= dbg_txdata;
            txen <= ~txen;
        end
`endif

        if (data_rd && data_addr == 24'hf0004)              // UART rx data port
        begin
            data_in_value <= rxdata;
            rxrdy <= 0;
        end
        else if (rxen != rxen0)
        begin
            if (rxrdy)
                rxovf <= 1;

            rxrdy <= 1;
        end

`ifdef SIMULATION
        if (data_rd && data_addr[23:15] == 9'b0)
`else
  `ifdef EXTENDED_MEM
        if (data_rd && data_addr[23:13] == 11'b0)
  `else
        if (data_rd && data_addr[23:10] == 14'b0)
  `endif
`endif
            data_in_value <= rom_out_value;

        if (data_rd2 && data_addr[23:16] == 8'h01)
            data_in_value <= dataram_out;

        /* dcache STATUS register: addr 0x0A0024 (n=9, byte offset 9*4=0x24) */
        if (data_rd && data_addr == 24'h0A0024)
            data_in_value <= {31'b0, gpu_busy};

        if (data_rd && data_addr == 24'hf0010)               // icache write busy
            data_in_value <= {31'b0, icache_wr_busy};

        /* X SDRAM data cache read result */
        if (icache_data_valid)
            data_in_value <= icache_data_out;

    end
endmodule

