`default_nettype none
// Tiny Tapeout RV32I SoC top: bus decode, pin mux, SYS/GPIO block + UART.
// Memory map by addr[29:28]: 00/11 -> QSPI PSRAM, 01 -> SRAM, 10 -> peripherals.
// Peripherals at 0x2000_0000 + block*0x100: block 0 SYS/GPIO, 1 UART,
// 2-4 timer/SPI/I2C (unmapped in phase 1: read 0, writes ignored).
module tt_um_rhgndf_rv32i_soc #(
    parameter SRAM_BYTES = 256
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------- core bus
    wire        mem_valid;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata;

    wire irq_timer = 1'b0; // timer block unmapped in phase 1
    wire irq_ext;

    rv32i_core cpu (
        .clk(clk), .rst_n(rst_n),
        .mem_valid(mem_valid), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .irq_timer(irq_timer), .irq_ext(irq_ext)
    );

    // ---------------- bus decode
    wire sel_sram   = (mem_addr[29:28] == 2'b01);
    wire sel_periph = (mem_addr[29:28] == 2'b10);
    wire sel_psram  = !sel_sram && !sel_periph;

    // ---------------- QSPI PSRAM
    wire        psram_ready;
    wire [31:0] psram_rdata;
    wire        psram_sck, psram_csn;
    wire [3:0]  psram_sd_out, psram_sd_oe;
    wire [3:0]  memcfg_dummy;
    wire        memcfg_late;

    qspi_psram psram (
        .clk(clk), .rst_n(rst_n),
        .req(mem_valid && sel_psram),
        .wr(|mem_wstrb),
        .addr(mem_addr[23:0]),
        .wdata(mem_wdata),
        .wstrb(mem_wstrb),
        .ready(psram_ready),
        .rdata(psram_rdata),
        .cfg_dummy(memcfg_dummy),
        .cfg_late_sample(memcfg_late),
        .sck(psram_sck), .cs_n(psram_csn),
        .sd_out(psram_sd_out), .sd_oe(psram_sd_oe), .sd_in(uio_in[5:2])
    );

    // ---------------- internal SRAM
    wire        sram_ready;
    wire [31:0] sram_rdata;
    sram #(.SRAM_BYTES(SRAM_BYTES)) isram (
        .clk(clk),
        .req(mem_valid && sel_sram),
        .addr(mem_addr),
        .wdata(mem_wdata),
        .wstrb(mem_wstrb),
        .ready(sram_ready),
        .rdata(sram_rdata)
    );

    // ---------------- peripherals (1-cycle ready)
    wire periph_ready = 1'b1;
    wire [3:0] pblk  = mem_addr[11:8];
    wire [5:0] preg  = mem_addr[7:2];
    wire       p_req = mem_valid && sel_periph;

    wire [31:0] sys_rdata, uart_rdata;
    wire        uart_tx;
    wire        uart_rx_irq;
    wire [7:0]  gpio_out, gpio_alt;

    sys_gpio sysblk (
        .clk(clk), .rst_n(rst_n),
        .req(p_req && pblk == 4'd0),
        .regsel(preg[1:0]),
        .wr(|mem_wstrb),
        .wdata(mem_wdata),
        .rdata(sys_rdata),
        .ui_in(ui_in),
        .gpio_out(gpio_out), .gpio_alt(gpio_alt),
        .memcfg_dummy(memcfg_dummy), .memcfg_late(memcfg_late)
    );

    uart uart_blk (
        .clk(clk), .rst_n(rst_n),
        .req(p_req && pblk == 4'd1),
        .regsel(preg[3:0]),
        .wr(|mem_wstrb),
        .wdata(mem_wdata),
        .rdata(uart_rdata),
        .rx(ui_in[7]),
        .tx(uart_tx),
        .irq(uart_rx_irq)
    );
    assign irq_ext = uart_rx_irq;

    // ---------------- read mux / ready
    always @(*) begin
        if (sel_sram)        mem_rdata = sram_rdata;
        else if (sel_periph) mem_rdata = (pblk == 4'd0) ? sys_rdata :
                                         (pblk == 4'd1) ? uart_rdata : 32'b0;
        else                 mem_rdata = psram_rdata;
    end
    assign mem_ready = mem_valid &&
        (sel_sram ? sram_ready : sel_periph ? periph_ready : psram_ready);

    // ---------------- output pin mux: uo = GPIO_ALT ? alt_fn : GPIO_OUT
    wire [7:0] alt_fn = {3'b0, 1'b0 /*timer pwm*/, 1'b1 /*spi cs_n*/,
                         1'b0 /*spi mosi*/, 1'b0 /*spi sck*/, uart_tx};
    assign uo_out = (gpio_alt & alt_fn) | (~gpio_alt & gpio_out);

    // ---------------- uio pins
    assign uio_out = {2'b0 /*i2c*/, psram_sd_out, psram_sck, psram_csn};
    assign uio_oe  = {2'b0, psram_sd_oe, 2'b11};

    // phase-1 unused inputs (i2c pins, unused psram pins, ena, addr bits)
    wire _unused = &{1'b0, uio_in[7:6], uio_in[1:0], ena, preg[5:4], 1'b0};

endmodule

// ---------------- SYS/GPIO block (block 0, regs = addr[7:2] & 3)
/* verilator lint_off DECLFILENAME */
module sys_gpio (
/* verilator lint_on DECLFILENAME */
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [1:0]  regsel,
    input  wire        wr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire [7:0]  ui_in,
    output reg  [7:0]  gpio_out,
    output reg  [7:0]  gpio_alt,
    output reg  [3:0]  memcfg_dummy,
    output reg         memcfg_late
);
    reg [7:0] ui_sync1, ui_sync2;
    wire _unused = &{1'b0, wdata[31:8], 1'b0};

    always @(*) begin
        case (regsel)
        2'd0:    rdata = {24'b0, gpio_out};
        2'd1:    rdata = {24'b0, ui_sync2};
        2'd2:    rdata = {24'b0, gpio_alt};
        default: rdata = {27'b0, memcfg_late, memcfg_dummy};
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            gpio_out    <= 8'b0;
            gpio_alt    <= 8'h1F;
            memcfg_dummy<= 4'd6;
            memcfg_late <= 1'b0;
            ui_sync1    <= 8'b0;
            ui_sync2    <= 8'b0;
        end else begin
            ui_sync1 <= ui_in;
            ui_sync2 <= ui_sync1;
            if (req && wr) begin
                case (regsel)
                2'd0: gpio_out    <= wdata[7:0];
                2'd2: gpio_alt    <= wdata[7:0];
                2'd3: {memcfg_late, memcfg_dummy} <= wdata[4:0];
                default: ;
                endcase
            end
        end
    end
endmodule
