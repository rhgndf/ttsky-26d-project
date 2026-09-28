`default_nettype none
// 24-bit free-running timer (addr[4:2]):
//   0x00 COUNT [23:0] rw — increments every clk; resets to 0 on match
//   0x04 CMP   [23:0] rw (reset all-ones); on COUNT==CMP: COUNT<=0, flag<=1
//   0x08 CTRL/STATUS: [0] irq enable (rw), [1] match flag (read; write 1 to clear)
// irq = flag & irq_en (level).
module timer (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [2:0]  regsel,   // addr[4:2]
    input  wire        wr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire        irq
);

    reg [23:0] count, cmp;
    reg        irq_en, flag;

    assign irq = flag & irq_en;
    wire _unused = &{1'b0, wdata[31:24], regsel[2], 1'b0};

    always @(*) begin
        case (regsel)
        3'd0:    rdata = {8'b0, count};
        3'd1:    rdata = {8'b0, cmp};
        3'd2:    rdata = {30'b0, flag, irq_en};
        default: rdata = 32'b0;
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            count  <= 24'b0;
            cmp    <= 24'hFFFFFF;
            irq_en <= 1'b0;
            flag   <= 1'b0;
        end else begin
            // counter / match
            if (req && wr && regsel == 3'd0) begin
                count <= wdata[23:0];
            end else if (count == cmp) begin
                count <= 24'b0;
                flag  <= 1'b1;
            end else begin
                count <= count + 1;
            end
            // register writes
            if (req && wr) begin
                case (regsel)
                3'd1: cmp <= wdata[23:0];
                3'd2: begin
                    irq_en <= wdata[0];
                    if (wdata[1]) flag <= 1'b0;
                end
                default: ;
                endcase
            end
        end
    end

endmodule
