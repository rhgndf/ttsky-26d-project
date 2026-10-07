`default_nettype none
// GPIO peripheral: any address with adr[31]=1 maps here.
// Read path lives in the top (returns ui_in / uio_in[7] / timer).
// Write -> gpio_out[7:0] = wdata[7:0] (uo_out)
// Write io -> io_out = wdata_io[0], io_oe = wdata_io[1] (uio[7] bidir)
module gpio (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        we,
    input  wire [7:0]  wdata,
    output reg  [7:0]  gpio_out,
    input  wire        we_io,
    input  wire [1:0]  wdata_io,
    output reg         io_out,
    output reg         io_oe
);
    always @(posedge clk) begin
        if (!rst_n) begin
            gpio_out <= 8'b0;
            io_out   <= 1'b0;
            io_oe    <= 1'b0;
        end else begin
            if (we)    gpio_out <= wdata;
            if (we_io) begin
                io_out <= wdata_io[0];
                io_oe  <= wdata_io[1];
            end
        end
    end
endmodule
`default_nettype wire
