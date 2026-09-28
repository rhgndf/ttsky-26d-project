`default_nettype none
`timescale 1ns / 1ps

/* Testbench: tt_um_rhgndf_rv32i_soc + QSPI PSRAM model (256 KB).
   Firmware image: +HEX=<path> plusarg ($readmemh, byte-wide verilog hex).
   +SPI_LOOP=1: loop SPI MOSI (uo_out[2]) back into MISO (ui_in[0]).
   I2C slave model at addr 0x50 (EEPROM-like pointer) on uio[7:6].
   Exposes tohost_flag/tohost_val and psram error to cocotb. */
module tb ();

  initial begin
    $dumpfile("tb.fst");
    $dumpvars(0, tb);
    #1;
  end

  reg clk;
  reg rst_n;
  reg ena;
  reg [7:0] ui_in;
  wire [7:0] uio_in;
  wire [7:0] uo_out;
  wire [7:0] uio_out;
  wire [7:0] uio_oe;
`ifdef GL_TEST
  wire VPWR = 1'b1;
  wire VGND = 1'b0;
`endif

  integer spi_loop;
  initial begin
    if (!$value$plusargs("SPI_LOOP=%d", spi_loop)) spi_loop = 0;
  end

  tt_um_rhgndf_rv32i_soc user_project (
`ifdef GL_TEST
      .VPWR(VPWR),
      .VGND(VGND),
`endif
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (ena),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // ---- PSRAM bus: uio[5:2] resolved between DUT and model
  wire [3:0] host_sd_oe  = uio_oe[5:2];
  wire [3:0] host_sd_out = uio_out[5:2];
  wire [3:0] mdl_drv, mdl_oe;
  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : sd_res
      assign uio_in[2+i] = host_sd_oe[i] ? host_sd_out[i] :
                           mdl_oe[i]     ? mdl_drv[i]     : 1'bz;
    end
  endgenerate
  assign uio_in[1:0] = uio_out[1:0]; // SCK, CS_n loop back (unused by DUT)

  // ---- I2C lines: DUT open-drain + slave model open-drain, pulled high
  wire sda_drv, scl_drv;
  assign uio_in[7] = uio_oe[7] ? 1'b0 : (scl_drv ? 1'b0 : 1'b1); // SCL
  assign uio_in[6] = uio_oe[6] ? 1'b0 : (sda_drv ? 1'b0 : 1'b1); // SDA

  wire i2c_error;

  i2c_slave_model u_i2c (
      .scl (uio_in[7]),
      .sda (uio_in[6]),
      .sda_drv (sda_drv),   // drives SDA low when 1 (open drain)
      .error (i2c_error)
  );
  assign scl_drv = 1'b0;   // slave never stretches

  // ---- SPI loopback option: MOSI -> MISO
  always @(*) begin
    ui_in = 8'b0;
    if (spi_loop) ui_in[0] = uo_out[2]; // MOSI -> MISO
  end

  wire        psram_error;
  wire        tohost_flag;
  wire [31:0] tohost_val;

  psram_model #(.SIZE(256*1024)) psram (
      .sck        (uio_out[1]),
      .cs_n       (uio_out[0]),
      .sd         (uio_in[5:2]),
      .host_oe    (host_sd_oe),
      .sd_drv     (mdl_drv),
      .sd_oe      (mdl_oe),
      .error      (psram_error),
      .tohost_flag(tohost_flag),
      .tohost_val (tohost_val)
  );

endmodule
