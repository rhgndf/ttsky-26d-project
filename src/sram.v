`default_nettype none
// Internal SRAM: word-organized 32-bit with byte write enables, single-cycle.
module sram #(
    parameter SRAM_BYTES = 256
) (
    input  wire        clk,
    input  wire        req,
    input  wire [31:0] addr,   // byte address; word index = addr[$clog2(SRAM_BYTES)-1:2]
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,  // 0 = read
    output wire        ready,
    output wire [31:0] rdata
);
    localparam WORDS = SRAM_BYTES / 4;
    localparam AW    = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];

    assign ready = req; // single-cycle

    wire [AW-1:0] widx = addr[AW+1:2];
    wire _unused = &{1'b0, addr[31:AW+2], addr[1:0], 1'b0};

    assign rdata = mem[widx]; // combinational read: valid the same cycle ready fires

    always @(posedge clk) begin
        if (req && wstrb != 0) begin
            if (wstrb[0]) mem[widx][7:0]   <= wdata[7:0];
            if (wstrb[1]) mem[widx][15:8]  <= wdata[15:8];
            if (wstrb[2]) mem[widx][23:16] <= wdata[23:16];
            if (wstrb[3]) mem[widx][31:24] <= wdata[31:24];
        end
    end

endmodule
