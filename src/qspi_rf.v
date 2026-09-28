`default_nettype none
// qspi_rf — merged QSPI engine + register-file-in-PSRAM adapter (lean v4).
//
// One engine serves the whole SoC: SERV ibus/dbus memory txns and the
// PSRAM-resident register file (x[i] at PSRAM word 0x7FFF00+4i). Exactly two
// 32-bit data registers, both loaded straight from the pads (shift right by
// 4, sd_in into [31:28]):
//   B1 = rs1 stream AND rd capture. Rotates right by 1 on (stream|wen0),
//        inserting (wen0 ? wdata0 : B1[0]) at [31]; after an instruction's 32
//        wen0 bits B1 == rd. `dirty` (any wen0) forces a 4-byte 0x38 write of
//        B1 to x[wreg0] before the next memory or RF transaction.
//   B2 = rs2 stream AND ibus/dbus read data. rdt = per-byte nibble swap.
// RF words in PSRAM are stored LSN first so B1[0] is the register's bit 0.
//
// One 5-bit step counter counts SCK periods within a txn (cmd 0-7, addr
// 8-13, read mode 14-15 / dummy 16-19 / data 20-27; write data 14..14+2*len-1)
// and then the 32-cycle stream window. sd_out/sd_oe/cs are combinational on
// {state, step}; they only change on the clk edge that lowers SCK because
// step only advances there. sd_in is sampled on the rising edge.
module qspi_rf (
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
    // SERV ibus (memory region only; peripheral filtered by caller)
    input  wire        i_ibus_req,
    input  wire [31:0] i_ibus_adr,
    output wire [31:0] o_ibus_rdt,   // shared: ibus and dbus read data
    output wire        o_ibus_ack,
    // SERV dbus (memory region only; peripheral/flash-wr handled by caller)
    input  wire        i_dbus_req,
    input  wire        i_dbus_we,
    input  wire [31:0] i_dbus_adr,
    input  wire [31:0] i_dbus_dat,
    input  wire [3:0]  i_dbus_sel,
    output wire        o_dbus_ack,
    // pads (CS0 flash, CS1 PSRAM)
    output wire        cs0_n,
    output wire        cs1_n,
    output reg         sck,
    output wire [3:0]  sd_out,
    output wire [3:0]  sd_oe,
    input  wire [3:0]  sd_in
);

    localparam [23:0] RF_BASE = 24'h7FFF00;

    localparam S_IDLE   = 3'd0;
    localparam S_FLUSH  = 3'd1;   // write B1 -> x[wreg0]
    localparam S_RD0    = 3'd2;   // read x[rreg0] -> B1
    localparam S_RD1    = 3'd3;   // read x[i_rreg1] -> B2
    localparam S_MEM    = 3'd4;   // ibus/dbus txn -> B2 / lane data
    localparam S_STREAM = 3'd5;

    reg  [2:0]  state;
    reg  [31:0] b1, b2;
    reg  [4:0]  step;
    reg  [1:0]  gap;
    reg  [4:0]  rreg0;      // rs1 index, latched 1 clk after rreq
    reg         rreq_r;     // rreq delayed (rreg0 valid then)
    reg         rf_go;      // an rreq is awaiting service
    reg         rf_ph;      // 0: next RF txn is RD0, 1: RD1
    reg         dirty;      // B1 holds an uncommitted rd write
    reg         mem_i;      // in-flight MEM txn owns ibus (1) / dbus (0)

    // -----------------------------------------------------------------
    // transaction decode (all combinational on stable SERV buses)
    // -----------------------------------------------------------------
    wire in_txn = (state == S_FLUSH) || (state == S_RD0) ||
                  (state == S_RD1)  || (state == S_MEM);
    wire is_rd_rf = (state == S_RD0) || (state == S_RD1);
    wire we   = (state == S_FLUSH) || (state == S_MEM && !mem_i && i_dbus_we);
    wire cs1  = (state != S_MEM) || (mem_i ? i_ibus_adr[24] : i_dbus_adr[24]);

    // byte lane decode for sub-word stores
    wire [1:0] wofs = i_dbus_sel[0] ? 2'd0 :
                      i_dbus_sel[1] ? 2'd1 :
                      i_dbus_sel[2] ? 2'd2 : 2'd3;
    wire [2:0] wlen = (i_dbus_sel == 4'b1111) ? 3'd4 :
                      ((i_dbus_sel == 4'b0011) || (i_dbus_sel == 4'b0110) ||
                       (i_dbus_sel == 4'b1100)) ? 3'd2 : 3'd1;

    wire [4:0] rfidx = (state == S_RD0) ? rreg0 :
                       (state == S_RD1) ? i_rreg1 : i_wreg0;
    wire [23:0] addr24 =
        (state == S_MEM)
            ? (mem_i ? i_ibus_adr[23:0]
                     : (we ? {i_dbus_adr[23:2], wofs} : i_dbus_adr[23:0]))
            : (RF_BASE | {17'b0, rfidx, 2'b00});

    // steps
    wire is_cmd  = (step < 5'd8);
    wire is_addr = (step >= 5'd8) && (step < 5'd14);
    wire rd_mode = !we && (step == 5'd14 || step == 5'd15);
    wire rd_data = !we && (step >= 5'd20);
    wire wr_data =  we && (step >= 5'd14);
    wire [2:0] wlen_eff = (state == S_FLUSH) ? 3'd4 : wlen;
    wire [4:0] last_step = we ? (5'd13 + {1'b0, wlen_eff, 1'b0}) : 5'd27;
    wire txn_done = in_txn && sck && (step == last_step);

    // outputs
    assign cs0_n = !(in_txn && !cs1);
    assign cs1_n = !(in_txn &&  cs1);

    wire [7:0] cmd   = we ? 8'h38 : 8'hEB;
    wire       cmdb  = cmd[3'd7 - step[2:0]];
    wire [3:0] adrn  = addr24[(5'd13 - step) * 4 +: 4];

    // store data: lane-placed like sel; first emitted nibble is the lane's
    // high nibble (wire order b0hi, b0lo, ...). RF write emits B1[3:0].
    wire [4:0] wdi   = step - 5'd14;
    wire [3:0] lane  = {2'b0, wofs} + wdi[4:1];
    wire [7:0] dbyte = i_dbus_dat[{lane[1:0], 3'b000} +: 8];
    wire [3:0] wnib  = (state == S_FLUSH) ? b1[3:0]
                                        : (wdi[0] ? dbyte[3:0] : dbyte[7:4]);

    assign sd_out = !in_txn ? 4'b0000 :
                    is_cmd  ? {3'b000, cmdb} :
                    is_addr ? adrn :
                    wr_data ? wnib : 4'b0000;
    assign sd_oe  = !in_txn ? 4'b0000 :
                    is_cmd  ? 4'b0001 :
                    (is_addr || wr_data || rd_mode) ? 4'b1111 : 4'b0000;

    // read capture: shift sd_in into [31:28] on each rising edge during data
    // steps. x0 registers read as zero (transaction still runs, input masked).
    wire       rd_samp = in_txn && rd_data && !sck;
    wire [3:0] sdin_m  = (is_rd_rf && (rfidx == 5'b0)) ? 4'b0000 : sd_in;

    // stream window: 32 shifts on the 32 cycles after the ready pulse
    wire stream_shift = (state == S_STREAM);
    wire rshift = stream_shift | i_wen0;

    assign o_rdata0 = b1[0];
    assign o_rdata1 = b2[0];

    // ready: combinational wreq passthrough (rf_shift_reg behaviour), plus
    // one pulse when the RF read data lands (entering S_STREAM).
    assign o_ready = i_wreq | (txn_done && (state == S_RD1));

    assign o_dbus_ack = txn_done && (state == S_MEM) && !mem_i;
    assign o_ibus_ack = txn_done && (state == S_MEM) &&  mem_i;

    wire [31:0] rdt = {b2[27:24], b2[31:28], b2[19:16], b2[23:20],
                       b2[11:8],  b2[15:12], b2[3:0],   b2[7:4]};
    assign o_ibus_rdt = rdt;

    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            b1     <= 32'b0;
            b2     <= 32'b0;
            step   <= 5'b0;
            sck    <= 1'b0;
            gap    <= 2'b0;
            rreg0  <= 5'b0;
            rreq_r <= 1'b0;
            rf_go  <= 1'b0;
            rf_ph  <= 1'b0;
            dirty  <= 1'b0;
            mem_i  <= 1'b0;
        end else begin
            rreq_r <= i_rreq;
            if (rreq_r) begin
                rreg0 <= i_rreg0;
                rf_go <= 1'b1;
                rf_ph <= 1'b0;
            end

            // data registers
            if (rd_samp && (state == S_RD0))
                b1 <= {sdin_m, b1[31:4]};
            else if (state == S_FLUSH && wr_data && sck)
                b1 <= {b1[3:0], b1[31:4]};   // rotate out written nibble
            else if (rshift)
                b1 <= {i_wen0 ? i_wdata0 : b1[0], b1[31:1]};

            if (rd_samp && (state != S_RD0))
                b2 <= {sdin_m, b2[31:4]};
            else if (rshift)
                b2 <= {b2[0], b2[31:1]};

            if (i_wen0)
                dirty <= 1'b1;

            case (state)
            S_IDLE: begin
                sck <= 1'b0;
                if (gap != 0)
                    gap <= gap - 2'd1;
                else if (dirty && (rf_go || i_dbus_req || i_ibus_req)) begin
                    state <= S_FLUSH;
                    step  <= 5'b0;
                end else if (rf_go) begin
                    state <= rf_ph ? S_RD1 : S_RD0;
                    step  <= 5'b0;
                end else if (i_dbus_req) begin
                    state <= S_MEM;
                    mem_i <= 1'b0;
                    step  <= 5'b0;
                end else if (i_ibus_req) begin
                    state <= S_MEM;
                    mem_i <= 1'b1;
                    step  <= 5'b0;
                end
            end

            S_FLUSH, S_RD0, S_RD1, S_MEM: begin
                sck <= ~sck;
                if (sck) begin                 // SCK falls: advance step
                    if (txn_done) begin
                        sck  <= 1'b0;
                        gap  <= 2'd1;
                        step <= 5'b0;
                        case (state)
                        S_FLUSH: begin
                            dirty <= 1'b0;
                            state <= S_IDLE;
                        end
                        S_RD0: begin
                            rf_ph <= 1'b1;
                            state <= S_IDLE;
                        end
                        S_RD1: begin
                            rf_go <= 1'b0;
                            state <= S_STREAM;
                        end
                        default: state <= S_IDLE;   // S_MEM: ack pulse this clk
                        endcase
                    end else
                        step <= step + 5'd1;
                end
            end

            S_STREAM: begin
                step <= step + 5'd1;
                if (step == 5'd31)
                    state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end

    wire _unused = &{1'b0, i_ibus_adr[31:25], i_dbus_adr[31:25], lane[3:2],
                     i_dbus_adr[1:0], 1'b0};

endmodule
`default_nettype wire
