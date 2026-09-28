`default_nettype none
// UART 8N1. Register block (word addr, reg = addr[3:2]):
//   0x00 DATA: write = TX byte (ignored if busy); read = last RX byte, clears rx_valid/overrun
//   0x04 STATUS ro: [0] tx_busy, [1] rx_valid, [2] rx_overrun
//   0x08 DIV rw [15:0]: clocks per bit, reset 434
//   0x0C CTRL rw: [0] rx interrupt enable (irq = rx_valid & en)
module uart (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        req,
    input  wire [3:0]  regsel,   // addr[5:2] (only 0..3 used)
    input  wire        wr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    input  wire        rx,
    output wire        tx,
    output wire        irq
);

    reg [15:0] div;
    reg        rx_irq_en;
    reg [7:0]  rx_data;
    reg        rx_valid, rx_overrun;

    // -------- TX
    reg        tx_busy;
    reg [9:0]  tx_shift;    // {stop, data[7:0], start}
    reg [3:0]  tx_bitcnt;
    reg [15:0] tx_clkcnt;
    reg        tx_out;
    assign tx = tx_out;

    // -------- RX (2-FF sync, mid-bit sample)
    reg [2:0]  rx_sync;
    wire       rx_in = rx_sync[2];
    reg        rx_busy;
    reg [3:0]  rx_bitcnt;
    reg [15:0] rx_clkcnt;
    reg [7:0]  rx_shift;

    assign irq = rx_valid & rx_irq_en;
    wire _unused = &{1'b0, regsel[3:2], wdata[31:16], tx_shift[0], 1'b0};

    always @(*) begin
        case (regsel[1:0])
        2'd0:    rdata = {24'b0, rx_data};
        2'd1:    rdata = {29'b0, rx_overrun, rx_valid, tx_busy};
        2'd2:    rdata = {16'b0, div};
        default: rdata = {31'b0, rx_irq_en};
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            div        <= 16'd434;
            rx_irq_en  <= 1'b0;
            rx_valid   <= 1'b0;
            rx_overrun <= 1'b0;
            tx_busy    <= 1'b0;
            tx_out     <= 1'b1;
            rx_busy    <= 1'b0;
            rx_sync    <= 3'b111;
        end else begin
            rx_sync <= {rx_sync[1:0], rx};

            // register writes
            if (req && wr) begin
                case (regsel[1:0])
                2'd0: if (!tx_busy) begin
                    tx_shift  <= {1'b1, wdata[7:0], 1'b0};
                    tx_bitcnt <= 4'd10;
                    tx_clkcnt <= div;
                    tx_busy   <= 1'b1;
                    tx_out    <= 1'b0; // start bit
                end
                2'd2: div       <= wdata[15:0];
                2'd3: rx_irq_en <= wdata[0];
                default: ;
                endcase
            end
            // DATA read clears rx flags
            if (req && !wr && regsel[1:0] == 2'd0) begin
                rx_valid   <= 1'b0;
                rx_overrun <= 1'b0;
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
            end else if (!(req && wr && regsel[1:0] == 2'd0 && !tx_busy)) begin
                tx_out <= 1'b1;
            end

            // RX engine
            if (!rx_busy) begin
                if (!rx_in) begin // start bit edge
                    rx_busy   <= 1'b1;
                    rx_clkcnt <= {1'b0, div[15:1]}; // sample mid-bit
                    rx_bitcnt <= 4'd0;
                end
            end else begin
                if (rx_clkcnt > 1) begin
                    rx_clkcnt <= rx_clkcnt - 1;
                end else begin
                    rx_clkcnt <= div;
                    if (rx_bitcnt < 8) begin
                        rx_shift  <= {rx_in, rx_shift[7:1]};
                        rx_bitcnt <= rx_bitcnt + 1;
                    end else begin
                        // stop bit
                        rx_busy <= 1'b0;
                        if (rx_in) begin
                            if (rx_valid) rx_overrun <= 1'b1;
                            rx_data  <= rx_shift;
                            rx_valid <= 1'b1;
                        end
                    end
                end
            end
        end
    end

endmodule
