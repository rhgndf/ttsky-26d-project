`default_nettype none
`timescale 1ns / 1ps

/* Testbench: tt_um_rhgndf_rv32i_soc (SERV) + shared QSPI bus:
   uio[0]=CS0 flash (W25Q128 model, +HEX firmware), uio[6]=CS1 PSRAM (128KB),
   uio[1,2,4,5]=SD0-3, uio[3]=SCK, uio[7]=bidir GPIO (ext pull-up).
   Asserts: CS0 & CS1 never low together.
   Exposes tohost_flag/tohost_val and model errors to cocotb. */
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

  // Poll counter kept small so the timeout path is reachable in sim;
  // BUSY_POLLS below stays below the 2^4-1 limit for normal ops.
`ifdef GL_TEST
  tt_um_rhgndf_rv32i_soc user_project (   // gate netlist: no params
`else
  tt_um_rhgndf_rv32i_soc #(.POLL_BITS(4)) user_project (
`endif
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

  // ---- Shared SD bus: pins {5,4,2,1} = SD3,SD2,SD1,SD0
  wire [3:0] host_sd_oe  = {uio_oe[5],  uio_oe[4],  uio_oe[2],  uio_oe[1]};
  wire [3:0] host_sd_out = {uio_out[5], uio_out[4], uio_out[2], uio_out[1]};
  wire [3:0] sd_pins     = {uio_in[5],  uio_in[4],  uio_in[2],  uio_in[1]};

  wire [3:0] fl_drv, fl_oe, rm_drv, rm_oe;
  wire       cs0 = uio_out[0], cs1 = uio_out[6], sck = uio_out[3];

  genvar i;
  generate
    for (i = 0; i < 4; i = i + 1) begin : sd_res
      // SD bus bit i -> pin map: bit0=uio[1], bit1=uio[2], bit2=uio[4], bit3=uio[5]
      wire drv = host_sd_oe[i] ? host_sd_out[i] :
                 fl_oe[i]      ? fl_drv[i]      :
                 rm_oe[i]      ? rm_drv[i]      : 1'bz;
    end
  endgenerate
  assign uio_in[1] = sd_res[0].drv;
  assign uio_in[2] = sd_res[1].drv;
  assign uio_in[4] = sd_res[2].drv;
  assign uio_in[5] = sd_res[3].drv;
  assign uio_in[0] = cs0;
  assign uio_in[3] = sck;
  assign uio_in[6] = cs1;
  assign uio_in[7] = uio_oe[7] ? uio_out[7] : 1'b1;  // ext pull-up

  wire flash_error, psram_error;
  wire tohost_flag;
  wire [31:0] tohost_val;

  flash_model #(.SIZE(1024*1024), .BUSY_POLLS(3)) flash (
      .sck    (sck),
      .cs_n   (cs0),
      .sd     (sd_pins),
      .host_oe(host_sd_oe),
      .sd_drv (fl_drv),
      .sd_oe  (fl_oe),
      .error  (flash_error)
  );

  psram_model #(.SIZE(128*1024)) psram (
      .sck        (sck),
      .cs_n       (cs1),
      .sd         (sd_pins),
      .host_oe    (host_sd_oe),
      .sd_drv     (rm_drv),
      .sd_oe      (rm_oe),
      .error      (psram_error),
      .tohost_flag(tohost_flag),
      .tohost_val (tohost_val)
  );

  // ---- bus protocol assertions
  always @(posedge clk) begin
    if (rst_n && !cs0 && !cs1)
      $display("BUS_ERROR: CS0 and CS1 both low (t=%0t)", $time);
  end

  // contention: both models driving at once
  always @(*) begin
    if ((fl_oe & rm_oe) != 0)
      $display("BUS_ERROR: flash and psram both driving SD (t=%0t)", $time);
  end

  // GPIO inputs: idle, spi loopback unused for now
  always @(*) begin
    ui_in = 8'b0;
  end

endmodule
