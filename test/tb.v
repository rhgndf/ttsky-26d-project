`default_nettype none
`timescale 1ns / 1ps

/* Testbench: tt_um_rhgndf_rv32i_soc + QSPI PSRAM model (256 KB).
   Firmware image: +HEX=<path> plusarg ($readmemh, byte-wide verilog hex).
   PSRAM dummy cycles: +DUMMY=<n> plusarg (default 6, must match MEMCFG).
   Exposes tohost_flag/tohost_val and psram error to cocotb. */
module tb ();

  localparam SRAM_BYTES = 256;

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

  tt_um_rhgndf_rv32i_soc #(.SRAM_BYTES(SRAM_BYTES)) user_project (
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
  assign uio_in[7:6] = 2'b11;        // I2C pulled high (phase 2)

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
