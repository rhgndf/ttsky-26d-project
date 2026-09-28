`default_nettype none
// RV32I SoC top for Tiny Tapeout (1x1 tile) — per docs/architecture.md.
// Pinout:
//   ui_in[0] = SPI MISO (GPIO_IN reads all of ui_in)
//   uo_out   = {GPIO_OUT[3:0], spi_csn, mosi, sck, uart_tx}
//   uio[0]   = PSRAM CS_n (out), uio[1] = PSRAM SCK (out)
//   uio[5:2] = PSRAM SD3..0 (bidir; SD0 = uio[2])
//   uio[6]   = I2C SDA open-drain, uio[7] = I2C SCL open-drain
// Memory map: addr[29:28]==2'b10 -> peripherals at 0x2000_0000 + block*0x100;
//             everything else -> PSRAM byte address [23:0].
module tt_um_rhgndf_rv32i_soc (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------- CPU <-> fabric bus
    wire        mem_valid;
    wire        mem_ready;
    wire [31:0] mem_addr;
    wire [31:0] mem_wdata;
    wire [3:0]  mem_wstrb;
    wire [31:0] mem_rdata;

    wire        periph   = (mem_addr[29:28] == 2'b10);
    wire [3:0]  pblk     = mem_addr[11:8];
    wire        cpu_wr   = |mem_wstrb;

    // ---------------- PSRAM channel
    wire        psram_ready;
    wire [31:0] psram_rdata;
    wire        psram_sck, psram_csn;
    wire [3:0]  psram_sd_out, psram_sd_oe;

    qspi_psram u_psram (
        .clk(clk), .rst_n(rst_n),
        .req(mem_valid && !periph),
        .wr(cpu_wr),
        .addr(mem_addr[23:0]),
        .wdata(mem_wdata),
        .ready(psram_ready),
        .rdata(psram_rdata),
        .sck(psram_sck), .cs_n(psram_csn),
        .sd_out(psram_sd_out), .sd_oe(psram_sd_oe),
        .sd_in(uio_in[5:2])
    );

    // ---------------- peripherals
    // Block 0: GPIO (0x00 OUT[3:0] -> uo_out[7:4]; 0x04 IN = ui_in)
    reg [3:0] gpio_out;
    wire      gpio_req = mem_valid && periph && pblk == 4'h0;
    reg [31:0] gpio_rdata;
    always @(*) begin
        case (mem_addr[3:2])
        2'd1:    gpio_rdata = {24'b0, ui_in};
        default: gpio_rdata = {28'b0, gpio_out};
        endcase
    end
    always @(posedge clk) begin
        if (!rst_n) gpio_out <= 4'b0;
        else if (gpio_req && cpu_wr && mem_addr[3:2] == 2'd0)
            gpio_out <= mem_wdata[3:0];
    end

    // Block 1: UART TX
    wire        uart_req = mem_valid && periph && pblk == 4'h1;
    wire [31:0] uart_rdata;
    wire        uart_tx;
    uart u_uart (
        .clk(clk), .rst_n(rst_n),
        .req(uart_req), .regsel(mem_addr[3:2]), .wr(cpu_wr),
        .wdata(mem_wdata), .rdata(uart_rdata), .tx(uart_tx)
    );

    // Block 2: TIMER
    wire        timer_req = mem_valid && periph && pblk == 4'h2;
    wire [31:0] timer_rdata;
    wire        irq_timer;
    timer u_timer (
        .clk(clk), .rst_n(rst_n),
        .req(timer_req), .regsel(mem_addr[4:2]), .wr(cpu_wr),
        .wdata(mem_wdata), .rdata(timer_rdata), .irq(irq_timer)
    );

    // Blocks 3+4: shared SPI/I2C serial engine
    wire        spi_req  = mem_valid && periph && pblk == 4'h3;
    wire        i2c_req  = mem_valid && periph && pblk == 4'h4;
    wire [31:0] spi_rdata, i2c_rdata;
    wire        spi_sck, spi_mosi, spi_csn;
    wire        i2c_sda_oe, i2c_scl_oe;
    serial u_serial (
        .clk(clk), .rst_n(rst_n),
        .spi_req(spi_req), .spi_regsel(mem_addr[3:2]), .spi_wr(cpu_wr),
        .wdata(mem_wdata), .spi_rdata(spi_rdata),
        .i2c_req(i2c_req), .i2c_regsel(mem_addr[3:2]), .i2c_wr(cpu_wr),
        .i2c_rdata(i2c_rdata),
        .spi_sck(spi_sck), .spi_mosi(spi_mosi), .spi_miso(ui_in[0]),
        .spi_csn(spi_csn),
        .i2c_sda_oe(i2c_sda_oe), .i2c_scl_oe(i2c_scl_oe),
        .sda_in(uio_in[6]), .scl_in(uio_in[7])
    );

    // ---------------- peripheral read mux / ready
    wire [31:0] periph_rdata = (pblk == 4'h1) ? uart_rdata  :
                               (pblk == 4'h2) ? timer_rdata :
                               (pblk == 4'h3) ? spi_rdata   :
                               (pblk == 4'h4) ? i2c_rdata   :
                                                gpio_rdata; // 0 and unmapped
    assign mem_ready = periph ? mem_valid : psram_ready;
    assign mem_rdata = periph ? periph_rdata : psram_rdata;

    // ---------------- core (external interrupt: none wired)
    rv32i_core u_core (
        .clk(clk), .rst_n(rst_n),
        .mem_valid(mem_valid), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .irq_timer(irq_timer), .irq_ext(1'b0)
    );

    // ---------------- pinout
    assign uo_out  = {gpio_out, spi_csn, spi_mosi, spi_sck, uart_tx};
    assign uio_out = {1'b0, 1'b0, psram_sd_out, psram_sck, psram_csn};
    assign uio_oe  = {i2c_scl_oe, i2c_sda_oe, psram_sd_oe, 1'b1, 1'b1};

    wire _unused = &{1'b0, ena, ui_in[7:1], uio_in[1:0], uio_in[7:6], mem_addr[31:30], mem_addr[27:12],
                     mem_addr[1:0], 1'b0};

endmodule
