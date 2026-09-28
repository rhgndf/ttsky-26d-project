`default_nettype none
// UART TX only, 8N1. Register block (addr[3:2]):
//   0x00 DATA: write = start TX of [7:0] (ignored if busy)
//   0x04 STATUS ro: [0] tx_busy
//   0x08 DIV rw [7:0]: clocks per bit, reset 216
module uart (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [1:0]  regsel,   // addr[3:2]
    input  wire        wr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        tx
);

    reg [7:0]  div;
    reg        tx_busy;
    reg [9:0]  tx_shift;    // {stop, data[7:0], start}
    reg [3:0]  tx_bitcnt;
    reg [7:0]  tx_clkcnt;
    reg        tx_out;
    assign tx = tx_out;
    wire _unused = &{1'b0, wdata[31:8], tx_shift[0], 1'b0};

    always @(*) begin
        case (regsel)
        2'd1:    rdata = {31'b0, tx_busy};
        2'd2:    rdata = {24'b0, div};
        default: rdata = 32'b0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            div      <= 8'd216;
            tx_busy  <= 1'b0;
            tx_out   <= 1'b1;
            tx_shift <= 10'b0; tx_bitcnt <= 4'b0; tx_clkcnt <= 8'b0;
        end else begin
            // register writes
            if (req && wr) begin
                case (regsel)
                2'd0: if (!tx_busy) begin
                    tx_shift  <= {1'b1, wdata[7:0], 1'b0};
                    tx_bitcnt <= 4'd10;
                    tx_clkcnt <= div;
                    tx_busy   <= 1'b1;
                    tx_out    <= 1'b0; // start bit
                end
                2'd2: div <= wdata[7:0];
                default: ;
                endcase
            end

            // TX engine
            if (tx_busy) begin
                if (tx_clkcnt > 1) begin
                    tx_clkcnt <= tx_clkcnt - 1;
                end else begin
                    tx_clkcnt <= div;
                    tx_bitcnt <= tx_bitcnt - 1;
                    tx_out    <= tx_shift[1];
                    tx_shift  <= {1'b1, tx_shift[9:1]};
                    if (tx_bitcnt == 1) tx_busy <= 1'b0;
                end
            end else if (!(req && wr && regsel == 2'd0)) begin
                tx_out <= 1'b1;
            end
        end
    end

endmodule
