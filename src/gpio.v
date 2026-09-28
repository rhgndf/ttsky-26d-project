`default_nettype none
// GPIO peripheral: any address with adr[31]=1 maps here.
// Read path lives in the top (returns ui_in).
// Write -> gpio_out[7:0] = wdata[7:0] (uo_out)
module gpio (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        we,
    input  wire [7:0]  wdata,
    output reg  [7:0]  gpio_out
);
    always @(posedge clk) begin
        if (!rst_n) gpio_out <= 8'b0;
        else if (we) gpio_out <= wdata;
    end
endmodule
`default_nettype wire
