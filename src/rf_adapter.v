`default_nettype none
// Register file in PSRAM for SERV (mimics underserved rf_shift_reg timing).
//
// x[i] lives at PSRAM word 0x7FFF00 + 4*i (i=1..31; index 0 reads as 0).
//
// o_wreq / wen0: write bits always stream into buffer W (LSB first); wreg0 is
//   latched at o_wreq. W is dirty until flushed with a 4-byte 0x38 write to
//   x[wreg0]. A pending flush is performed before the next read request.
// o_rreq: flush dirty W, then read x[rreg0]->B1 and x[rreg1]->B2 via 0xEB
//   (index 0 loads zeros, skipping the transaction), pulse i_rf_ready once,
//   then stream B1[0]/B2[0] for 32 clocks while both regs shift right.
module rf_adapter (
    input  wire        clk,
    input  wire        rst_n,
    // SERV RF interface
    input  wire        i_wreq,
    input  wire        i_rreq,
    output wire        o_ready,
    input  wire [4:0]  i_rreg0,
    input  wire [4:0]  i_rreg1,
    output wire        o_rdata0,
    output wire        o_rdata1,
    input  wire        i_wen0,
    input  wire [4:0]  i_wreg0,
    input  wire        i_wdata0,
    // QSPI engine client port (always CS1, 4-byte ops)
    output reg         op_req,
    output wire        op_we,
    output wire [23:0] op_addr,
    output wire [31:0] op_wdata,
    input  wire [31:0] op_rdata,
    input  wire        op_done,
    input  wire        op_grant      // engine idle/accepting RF ops
);

    localparam RF_BASE = 24'h7FFF00;

    localparam S_IDLE = 0, S_FLUSH = 1, S_RD0 = 2, S_RD1 = 3, S_STREAM = 4;

    reg  [2:0]  state;
    reg  [31:0] b1, b2;      // read shift registers (stream LSB first)
    reg  [31:0] wbuf;        // write capture (LSB first); doubles as the
                             // completed-unflushed write once wcnt wraps
    reg  [5:0]  wcnt;        // bits captured in current episode (0..31)
    reg  [4:0]  wreg;        // destination of current/completed episode
    reg         wdirty;      // wbuf holds a complete uncommitted write
    reg  [4:0]  rreg0;       // rs1 index (needed 2 clks after rreq)
    reg  [5:0]  scnt;        // stream bit counter
    reg         rreq_r;      // rreq delayed 1 clk (rreg valid then)

    // Combinational op outputs: only one value is ever driven per state, so
    // mux over live regs instead of registering them.
    wire [4:0] op_idx = (state == S_RD0) ? rreg0  :
                        (state == S_RD1) ? i_rreg1 : wreg;
    assign op_we    = (state == S_FLUSH);
    assign op_addr  = RF_BASE + {17'b0, op_idx, 2'b00};
    assign op_wdata = wbuf;

    assign o_rdata0 = b1[0];
    assign o_rdata1 = b2[0];

    // rf_shift_reg behaviour: ready is high whenever SERV asserts wreq, and
    // pulses once when the read data is loaded (entering S_STREAM).
    wire enter_stream = (state == S_RD1) &&
                        ((i_rreg1 == 5'b0) || (op_req && op_done));
    assign o_ready = i_wreq | enter_stream;

    // All registers rotate on every shift in rf_shift_reg, so rd0/rd1 stay
    // live during write episodes too (SERV reads rs1 while writing rd for
    // iterative ops like shifts). One rotation per clock.
    wire stream_shift = (state == S_STREAM) && (scnt != 6'd0);
    wire rshift = stream_shift | i_wen0;

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            b1        <= 32'b0; b2 <= 32'b0;
            wbuf      <= 32'b0;
            wdirty    <= 1'b0;
            wreg      <= 5'b0;
            wcnt      <= 6'b0;
            rreg0     <= 5'b0;
            scnt      <= 6'b0;
            op_req    <= 1'b0;
        end else begin
            rreq_r <= i_rreq;
            // i_rreg0 is stable shortly after rreq; i_rreg1 is not (it still
            // shows rs1's field then) -- use it live at S_RD1, ~140 clks in.
            if (rreq_r)
                rreg0 <= i_rreg0;

            if (rshift) begin
                b1 <= {b1[0], b1[31:1]};
                b2 <= {b2[0], b2[31:1]};
            end

            // write bits always capture into W (in-stream or out); a word is
            // 32 wen0 bits possibly split across several wreq episodes (e.g.
            // shift ops write rd in two windows). On the 32nd bit the word is
            // complete and marked dirty; no further writes can arrive before
            // the flush finishes because SERV stalls until the next ready.
            if (i_wen0) begin
                if (!wdirty)
                    wbuf <= {i_wdata0, wbuf[31:1]};
                if (wcnt == 6'd0) wreg <= i_wreg0;
                if (wcnt == 6'd31) begin
                    wcnt    <= 6'b0;
                    wdirty  <= 1'b1;
                end else
                    wcnt <= wcnt + 6'd1;
            end

            case (state)
            S_IDLE: begin
                op_req <= 1'b0;
                if (rreq_r) begin
                    if (wdirty) begin
                        // flush buffered write before serving the read
                        op_req   <= 1'b1;
                        state    <= S_FLUSH;
                    end else
                        state <= S_RD0;
                end
            end
            S_FLUSH: begin
                op_req <= 1'b1;
                if (op_done) begin
                    op_req <= 1'b0;
                    wdirty <= 1'b0;
                    state  <= S_RD0;
                end
            end
            S_RD0: begin
                if (rreg0 == 0) begin
                    b1    <= 32'b0;
                    state <= S_RD1;
                end else begin
                    op_req  <= 1'b1;
                    if (op_done) begin
                        op_req <= 1'b0;
                        // keep rotation aligned if a write bit lands this clk
                        b1     <= rshift ? {op_rdata[0], op_rdata[31:1]} : op_rdata;
                        state  <= S_RD1;
                    end
                end
            end
            S_RD1: begin
                if (i_rreg1 == 0) begin
                    b2    <= 32'b0;
                    scnt  <= 6'd32;
                    state <= S_STREAM;
                end else begin
                    op_req  <= 1'b1;
                    if (op_done) begin
                        op_req <= 1'b0;
                        b2     <= rshift ? {op_rdata[0], op_rdata[31:1]} : op_rdata;
                        scnt   <= 6'd32;
                        state  <= S_STREAM;
                    end
                end
            end
            // 33-cycle window: scnt=32 cycle = the i_rf_ready pulse (no shift;
            // b[0] presented). Next 32 cycles present b[0..31] to SERV's count,
            // shifting at the end of each (rf_shift_reg's rd_active timing).
            S_STREAM: begin
                if (scnt != 0)
                    scnt <= scnt - 1;
                else
                    state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase


        end
    end

    wire _unused = &{1'b0, op_grant, wbuf[0], 1'b0};

endmodule
`default_nettype wire
