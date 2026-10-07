`default_nettype none
// tt_um_rhgndf_rv32i_soc — RV32I SoC for Tiny Tapeout 1x1
// SERV 1.4.0 (unmodified) + QSPI flash/PSRAM controller + RF-in-PSRAM adapter
// + GPIO.  Memory map (docs/architecture.md):
//   adr[31]=1, [29:28]=0 -> peripherals (GPIO / GPIO_IO / TIMER / FLASH_STATUS)
//   adr[31]=1, [28]=1    -> FLASH_PROG window, a[23:0] = op address
//   adr[31]=1, [29]=1    -> FLASH_ERASE window, a[23:0] = sector
//   adr[31]=0, [24]=0 -> flash CS0, adr[23:0], read-only (writes acked+ignored)
//   adr[31]=0, [24]=1 -> PSRAM CS1, base 0x0100_0000
// QSPI Pmod: uio[0]=CS0, [1]=SD0, [2]=SD1, [3]=SCK, [4]=SD2, [5]=SD3,
//            [6]=CS1, [7]=bidir GPIO (input after reset).
module tt_um_rhgndf_rv32i_soc #(
    parameter POLL_BITS = 20
) (
    input  wire [7:0] ui_in,    // GPIO_IN (ui_in[0] = SD card MISO later)
    output wire [7:0] uo_out,   // GPIO_OUT (uo_out[0] = UART TX by software)
    input  wire [7:0] uio_in,   // QSPI Pmod inputs
    output wire [7:0] uio_out,  // QSPI Pmod outputs
    output wire [7:0] uio_oe,   // QSPI Pmod output enables
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // ---------------------------------------------------------------
    // SERV core (unmodified, tag 1.4.0)
    // ---------------------------------------------------------------
    wire        rf_wreq, rf_rreq, rf_ready;
    wire [4:0]  rf_wreg0, rf_rreg0, rf_rreg1;
    wire        rf_wen0, rf_wdata0, rf_rdata0, rf_rdata1;

    wire        ibus_cyc, ibus_ack;
    wire [31:0] ibus_adr, ibus_rdt;
    wire        dbus_cyc, dbus_we, dbus_ack;
    wire [31:0] dbus_adr, dbus_dat, dbus_rdt;
    wire [3:0]  dbus_sel;

    /* verilator lint_off PINCONNECTEMPTY */
    serv_top #(
        .RESET_PC       (32'h0000_0000),
        .RESET_STRATEGY ("MINI"),
        .WITH_CSR       (0),
        .PRE_REGISTER   (1),
        .MDU            (0),
        .COMPRESSED     (0),
        .ALIGN          (0),
        .W              (1)
    ) cpu (
        .clk          (clk),
        .i_rst        (!rst_n),
        .i_timer_irq  (1'b0),

        .o_rf_rreq    (rf_rreq),
        .o_rf_wreq    (rf_wreq),
        .i_rf_ready   (rf_ready),
        .o_wreg0      (rf_wreg0),
        .o_wreg1      (),
        .o_wen0       (rf_wen0),
        .o_wen1       (),
        .o_wdata0     (rf_wdata0),
        .o_wdata1     (),
        .o_rreg0      (rf_rreg0),
        .o_rreg1      (rf_rreg1),
        .i_rdata0     (rf_rdata0),
        .i_rdata1     (rf_rdata1),

        .o_ibus_adr   (ibus_adr),
        .o_ibus_cyc   (ibus_cyc),
        .i_ibus_rdt   (ibus_rdt),
        .i_ibus_ack   (ibus_ack),

        .o_dbus_adr   (dbus_adr),
        .o_dbus_dat   (dbus_dat),
        .o_dbus_sel   (dbus_sel),
        .o_dbus_we    (dbus_we),
        .o_dbus_cyc   (dbus_cyc),
        .i_dbus_rdt   (dbus_rdt),
        .i_dbus_ack   (dbus_ack),

        .o_ext_funct3 (),
        .i_ext_ready  (1'b0),
        .i_ext_rd     (32'b0),
        .o_ext_rs1    (),
        .o_ext_rs2    (),
        .o_mdu_valid  ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------------------------------------------------------
    // qspi_rf — merged QSPI engine + RF-in-PSRAM adapter (lean v4).
    // Serves ibus/dbus memory txns and the PSRAM register file.
    // Peripheral and flash-region-write ops never reach it.
    // ---------------------------------------------------------------
    wire i_periph = ibus_adr[31];
    wire d_periph = dbus_adr[31] && (dbus_adr[29:28] == 2'b00);
    wire d_flash_wr = dbus_cyc && !dbus_adr[31] && dbus_we && !dbus_adr[24];

    wire [3:0] sd_out, sd_oe, sd_in;
    wire       cs0_n, cs1_n, sck;
    wire       eng_ibus_ack, eng_dbus_ack;
    wire [31:0] eng_rdt;
    wire       eng_wen, eng_timeout, fop_ack;

    // flash ops are address windows: adr[28]=PROG, adr[29]=ERASE, op
    // address = a[23:0]. FLASH_STATUS stays a peripheral reg at 0x8000_002C.
    wire       fop_store = dbus_cyc && dbus_we && dbus_adr[31] &&
                           (dbus_adr[28] || dbus_adr[29]);
    wire       fop_stall = fop_store && eng_wen;   // WEN=0 -> fast_ack no-op

    qspi_rf #(.POLL_BITS(POLL_BITS)) qrf (
        .clk        (clk),
        .rst_n      (rst_n),
        .i_wreq     (rf_wreq),
        .i_rreq     (rf_rreq),
        .o_ready    (rf_ready),
        .i_rreg0    (rf_rreg0),
        .i_rreg1    (rf_rreg1),
        .o_rdata0   (rf_rdata0),
        .o_rdata1   (rf_rdata1),
        .i_wen0     (rf_wen0),
        .i_wreg0    (rf_wreg0),
        .i_wdata0   (rf_wdata0),
        .i_ibus_req (ibus_cyc && !i_periph),
        .i_ibus_adr (ibus_adr),
        .o_ibus_rdt (eng_rdt),
        .o_ibus_ack (eng_ibus_ack),
        .i_dbus_req (dbus_cyc && !dbus_adr[31] && !d_flash_wr),
        .i_dbus_we  (dbus_we),
        .i_dbus_adr (dbus_adr),
        .i_dbus_dat (dbus_dat),
        .i_dbus_sel (dbus_sel),
        .o_dbus_ack (eng_dbus_ack),
        .i_stat_we  (d_periph && dbus_adr[5] && dbus_cyc && dbus_we &&
                      (dbus_adr[3:2] == 2'd3)),
        .o_wen      (eng_wen),
        .o_timeout  (eng_timeout),
        .i_fop_req  (fop_stall),
        .i_fop_erase(dbus_adr[29]),
        .o_fop_ack  (fop_ack),
        .cs0_n      (cs0_n),
        .cs1_n      (cs1_n),
        .sck        (sck),
        .sd_out     (sd_out),
        .sd_oe      (sd_oe),
        .sd_in      (sd_in)
    );

    // ---------------------------------------------------------------
    // GPIO peripheral
    // ---------------------------------------------------------------
    wire       gpio_we = d_periph && !dbus_adr[5] && dbus_cyc && dbus_we &&
                         (dbus_adr[3:2] == 2'd0);
    wire       gpio_io_we = d_periph && !dbus_adr[5] && dbus_cyc && dbus_we &&
                            (dbus_adr[3:2] == 2'd1);
    wire [7:0] gpio_out;
    wire       io_out, io_oe;
    gpio gpio_i (
        .clk      (clk),
        .rst_n    (rst_n),
        .we       (gpio_we),
        .wdata    (dbus_dat[7:0]),
        .gpio_out (gpio_out),
        .we_io    (gpio_io_we),
        .wdata_io (dbus_dat[1:0]),
        .io_out   (io_out),
        .io_oe    (io_oe)
    );

    // -------------------------------------------------------------
    // 16-bit free-running timer (read-only, wraps). No reset: the
    // counter need not start at a known value in silicon.
    // -------------------------------------------------------------
    reg [15:0] timer;
`ifndef __pnr__
    initial timer = 16'd0;
`endif
    always @(posedge clk) timer <= timer + 16'd1;

    // ---------------------------------------------------------------
    // bus returns
    //   peripheral: immediate ack, rdata = GPIO in
    //   memory:     ack on engine done; flash writes ignored (acked silently)
    // ---------------------------------------------------------------
    assign ibus_ack = i_periph ? ibus_cyc : eng_ibus_ack;
    assign ibus_rdt = i_periph ? {24'b0, ui_in} : eng_rdt;

    // Non-engine acks must be a single-cycle pulse: a level ack held over
    // multiple cycles makes SERV treat the store as repeatedly completing
    // and corrupts its serial pc/datapath state.
    reg ack_seen;
    always @(posedge clk) ack_seen <= dbus_cyc && dbus_ack;
    wire fast_ack = dbus_cyc && !ack_seen;

    assign dbus_ack = fop_stall    ? fop_ack :
                      dbus_adr[31] ? fast_ack :   // periph + window access
                      d_flash_wr   ? fast_ack :   // flash write: ack + drop
                      eng_dbus_ack;

    // flash status read: {wen,timeout}; other periph-block regs read 0
    wire [31:0] frdt = (dbus_adr[3:2] == 2'd3) ? {30'b0, eng_wen, eng_timeout}
                                             : 32'b0;
    assign dbus_rdt = d_periph ? (dbus_adr[5] ? frdt :
                                  dbus_adr[3] ? {16'b0, timer}
                                              : {23'b0, uio_in[7], ui_in})
                               : eng_rdt;

    // ---------------------------------------------------------------
    // pads: uio[0]=CS0 [1]=SD0 [2]=SD1 [3]=SCK [4]=SD2 [5]=SD3 [6]=CS1 [7]=CS2
    // ---------------------------------------------------------------
    assign uio_out = {io_out, cs1_n, sd_out[3], sd_out[2],
                      sck, sd_out[1], sd_out[0], cs0_n};
    assign uio_oe  = {io_oe, 1'b1, sd_oe[3], sd_oe[2],
                      1'b1, sd_oe[1], sd_oe[0], 1'b1};
    assign sd_in   = {uio_in[5], uio_in[4], uio_in[2], uio_in[1]};
    assign uo_out  = gpio_out;

    wire _unused = &{1'b0, ena, uio_in[6], uio_in[3], uio_in[0],
                     dbus_adr[30:25], ibus_adr[30:25], 1'b0};

endmodule
`default_nettype wire
