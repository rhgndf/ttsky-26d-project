`default_nettype none
// tt_um_rhgndf_rv32i_soc — RV32I SoC for Tiny Tapeout 1x1
// SERV 1.4.0 (unmodified) + QSPI flash/PSRAM controller + RF-in-PSRAM adapter
// + GPIO.  Memory map (docs/architecture.md):
//   adr[31]=1        -> peripherals (GPIO: read=ui_in, write=uo_out)
//   adr[31]=0, [24]=0 -> flash CS0, adr[23:0], read-only (writes acked+ignored)
//   adr[31]=0, [24]=1 -> PSRAM CS1, base 0x0100_0000
// QSPI Pmod: uio[0]=CS0, [1]=SD0, [2]=SD1, [3]=SCK, [4]=SD2, [5]=SD3,
//            [6]=CS1, [7]=CS2 (unused, driven high).
module tt_um_rhgndf_rv32i_soc (
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
    // QSPI engine + arbitration
    //   clients: RF adapter (highest) > dbus > ibus
    //   adr[31] (peripheral) ops never reach the engine — acked in-place.
    // ---------------------------------------------------------------
    wire        op_done;
    wire [31:0] op_rdata;

    // RF adapter request
    wire        rf_op_req, rf_op_we;
    wire [23:0] rf_op_addr;
    wire [31:0] rf_op_wdata;

    // bus decodes
    wire i_periph = ibus_adr[31];
    wire d_periph = dbus_adr[31];
    wire i_req = ibus_cyc & ~i_periph;
    wire d_req = dbus_cyc & ~d_periph;

    // dbus write byte lane decode: start = lowest set sel bit, len = popcount
    wire [1:0] d_wofs = dbus_sel[0] ? 2'd0 :
                        dbus_sel[1] ? 2'd1 :
                        dbus_sel[2] ? 2'd2 : 2'd3;
    wire [2:0] d_wlen = (dbus_sel == 4'b1111) ? 3'd4 :
                        ((dbus_sel == 4'b0011) || (dbus_sel == 4'b0110) ||
                         (dbus_sel == 4'b1100)) ? 3'd2 : 3'd1;

    // flash-region writes are acked+ignored: they never reach the engine
    wire       d_flash_wr = d_req && dbus_we && !dbus_adr[24];
    wire       d_eng      = d_req && !d_flash_wr;

    // engine client mux (RF pending first, then dbus, then ibus)
    wire [1:0] client = rf_op_req ? 2'd0 : (d_eng ? 2'd1 : 2'd2);
    wire       op_req   = rf_op_req | d_eng | i_req;
    wire       op_we    = (client == 2'd0) ? rf_op_we :
                          (client == 2'd1) ? dbus_we : 1'b0;
    wire       op_cs    = (client == 2'd0) ? 1'b1 :
                          (client == 2'd1) ? dbus_adr[24] : ibus_adr[24];
    wire [23:0] op_addr = (client == 2'd0) ? rf_op_addr :
                          (client == 2'd1) ? dbus_adr[23:0] : ibus_adr[23:0];
    wire [31:0] op_wdata = (client == 2'd0) ? rf_op_wdata : dbus_dat;
    wire [1:0]  op_wofs = (client == 2'd0) ? 2'd0 : d_wofs;
    wire [2:0]  op_wlen = (client == 2'd0) ? 3'd4 : d_wlen; // RF ops always 4B

    reg  [1:0]  client_r;  // client owning the in-flight txn
    wire        engine_idle;
    always @(posedge clk) begin
        if (!rst_n) client_r <= 2'd2;
        else if (op_req && engine_idle) client_r <= client;
    end

    wire [3:0] sd_out, sd_oe, sd_in;
    wire       cs0_n, cs1_n, sck;

    qspi_ctrl qspi (
        .clk      (clk),
        .rst_n    (rst_n),
        .op_req   (op_req),
        .op_we    (op_we),
        .op_cs    (op_cs),
        .op_addr  (op_addr),
        .op_wdata (op_wdata),
        .op_wofs  (op_wofs),
        .op_wlen  (op_wlen),
        .op_rdata (op_rdata),
        .op_done  (op_done),
        .op_ready (engine_idle),
        .cs0_n    (cs0_n),
        .cs1_n    (cs1_n),
        .sck      (sck),
        .sd_out   (sd_out),
        .sd_oe    (sd_oe),
        .sd_in    (sd_in)
    );


    // ---------------------------------------------------------------
    // RF adapter (register file in PSRAM)
    // ---------------------------------------------------------------
    rf_adapter rfa (
        .clk      (clk),
        .rst_n    (rst_n),
        .i_wreq   (rf_wreq),
        .i_rreq   (rf_rreq),
        .o_ready  (rf_ready),
        .i_rreg0  (rf_rreg0),
        .i_rreg1  (rf_rreg1),
        .o_rdata0 (rf_rdata0),
        .o_rdata1 (rf_rdata1),
        .i_wen0   (rf_wen0),
        .i_wreg0  (rf_wreg0),
        .i_wdata0 (rf_wdata0),
        .op_req   (rf_op_req),
        .op_we    (rf_op_we),
        .op_addr  (rf_op_addr),
        .op_wdata (rf_op_wdata),
        .op_rdata (op_rdata),
        .op_done  (op_done && client_r == 2'd0),
        .op_grant (engine_idle)
    );

    // ---------------------------------------------------------------
    // GPIO peripheral
    // ---------------------------------------------------------------
    wire       gpio_we = d_periph && dbus_cyc && dbus_we;
    wire [7:0] gpio_out;
    gpio gpio_i (
        .clk      (clk),
        .rst_n    (rst_n),
        .we       (gpio_we),
        .wdata    (dbus_dat[7:0]),
        .gpio_out (gpio_out)
    );

    // ---------------------------------------------------------------
    // bus returns
    //   peripheral: immediate ack, rdata = GPIO in
    //   memory:     ack on engine done; flash writes ignored (acked silently)
    // ---------------------------------------------------------------
    assign ibus_ack = i_periph ? ibus_cyc :
                      (op_done && client_r == 2'd2);
    assign ibus_rdt = i_periph ? {24'b0, ui_in} : op_rdata;

    // Non-engine acks must be a single-cycle pulse: a level ack held over
    // multiple cycles makes SERV treat the store as repeatedly completing
    // and corrupts its serial pc/datapath state.
    reg ack_seen;
    always @(posedge clk) ack_seen <= dbus_cyc && dbus_ack;
    wire fast_ack = dbus_cyc && !ack_seen;

    assign dbus_ack = d_periph   ? fast_ack :
                      d_flash_wr ? fast_ack :   // flash write: ack + drop
                      (op_done && client_r == 2'd1);
    assign dbus_rdt = d_periph ? {24'b0, ui_in} : op_rdata;

    // ---------------------------------------------------------------
    // pads: uio[0]=CS0 [1]=SD0 [2]=SD1 [3]=SCK [4]=SD2 [5]=SD3 [6]=CS1 [7]=CS2
    // ---------------------------------------------------------------
    assign uio_out = {1'b1, cs1_n, sd_out[3], sd_out[2],
                      sck, sd_out[1], sd_out[0], cs0_n};
    assign uio_oe  = {1'b1, 1'b1, sd_oe[3], sd_oe[2],
                      1'b1, sd_oe[1], sd_oe[0], 1'b1};
    assign sd_in   = {uio_in[5], uio_in[4], uio_in[2], uio_in[1]};
    assign uo_out  = gpio_out;

    wire _unused = &{1'b0, ena, uio_in[7:6], uio_in[3], uio_in[0],
                     dbus_adr[30:25], ibus_adr[30:25], 1'b0};

endmodule
`default_nettype wire
