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
module qspi_rf #(
    parameter POLL_BITS = 20
) (
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
    // flash erase/program controller (CS0). The op address is taken
    // live off dbus_adr (stable while the store is stalled).
    input  wire        i_stat_we,   // FLASH_STATUS store, sel[0] byte
    output wire        o_wen,
    output wire        o_timeout,
    input  wire        i_fop_req,   // PROG/ERASE store with WEN set
    input  wire        i_fop_erase,
    output wire        o_fop_ack,
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
    localparam S_FOP    = 3'd6;   // flash erase/program op (CS0)
    localparam F_WREN   = 2'd0;   // S_FOP sub-stages: WREN / CMD+data / POLL
    localparam F_CMD    = 2'd1;
    localparam F_POLL   = 2'd2;

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
    // flash erase/program controller (B2 doubles as the poll counter:
    // no read can be in flight while a stalled dbus store owns the engine)
    reg  [1:0]  fstg;       // F_WREN / F_CMD / F_POLL
    reg         fdat;       // CMD stage: address done, now quad data
    reg         fbusy;      // sampled BUSY bit from the last POLL
    reg         fop;        // a flash op is in progress (across CS gaps)
    reg         wen;        // STATUS bit1, write-enable
    reg         timeout;    // STATUS bit0, sticky

    // -----------------------------------------------------------------
    // transaction decode (all combinational on stable SERV buses)
    // -----------------------------------------------------------------
    wire in_txn = (state == S_FLUSH) || (state == S_RD0) ||
                  (state == S_RD1)  || (state == S_MEM) ||
                  (state == S_FOP);
    wire fop_st = (state == S_FOP);
    wire is_rd_rf = (state == S_RD0) || (state == S_RD1);
    wire we   = (state == S_FLUSH) || (state == S_MEM && !mem_i && i_dbus_we)
                || (fop_st && fdat);
    wire cs1  = !fop_st &&
                ((state != S_MEM) || (mem_i ? i_ibus_adr[24] : i_dbus_adr[24]));

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
    wire txn_done = in_txn && !fop_st && sck && (step == last_step);

    // S_FOP phase decode: every stage starts with a serial cmd (steps 0-7);
    // F_CMD then sends the op address serially on SD0 (steps 8-31) straight
    // from the stalled store's byte address; a program jumps back to step 14
    // for the existing quad write-data path; F_POLL releases the bus for
    // steps 8-15 (status byte on SD1).
    wire f_cmd  = fop_st && (step < 5'd8);
    wire f_addr = fop_st && (fstg == F_CMD) && !fdat && (step >= 5'd8);
    wire f_data = fop_st && fdat;
    wire [7:0] fcmd = (fstg == F_WREN) ? 8'h06 :
                      (fstg == F_CMD)  ? (i_fop_erase ? 8'h20 : 8'h32) : 8'h05;
    wire [23:0] fadr  = {i_dbus_adr[23:2], wofs};
    wire        fabit = fadr[5'd31 - step];

    // outputs
    assign cs0_n = !(in_txn && !cs1);
    assign cs1_n = !(in_txn &&  cs1);

    wire [7:0] cmd   = fop_st ? fcmd : (we ? 8'h38 : 8'hEB);
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
                    fop_st ? (f_cmd ? {3'b000, cmdb} :
                              f_addr ? {3'b000, fabit} :
                              f_data ? wnib : 4'b0000) :
                    is_cmd  ? {3'b000, cmdb} :
                    is_addr ? adrn :
                    wr_data ? wnib : 4'b0000;
    assign sd_oe  = !in_txn ? 4'b0000 :
                    fop_st ? ((f_cmd || f_addr) ? 4'b0001 :
                              f_data ? 4'b1111 : 4'b0000) :
                    is_cmd  ? 4'b0001 :
                    (is_addr || wr_data || rd_mode) ? 4'b1111 : 4'b0000;

    // read capture: shift sd_in into [31:28] on each rising edge during data
    // steps. x0 registers read as zero (transaction still runs, input masked).
    wire       rd_samp = in_txn && rd_data && !sck && !fop_st;
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

    // a POLL completes the op: BUSY clear -> done; pcnt full -> TIMEOUT
    assign o_fop_ack = fop_st && (fstg == F_POLL) && sck && (step == 5'd15)
                       && (!fbusy || (&b2[POLL_BITS-1:0]));

    assign o_wen     = wen;
    assign o_timeout = timeout;

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
            fstg   <= F_WREN;
            fdat   <= 1'b0;
            fbusy  <= 1'b0;
            fop    <= 1'b0;
            wen    <= 1'b0;
            timeout<= 1'b0;
        end else begin
            rreq_r <= i_rreq;
            if (rreq_r) begin
                rreg0 <= i_rreg0;
                rf_go <= 1'b1;
                rf_ph <= 1'b0;
            end

            // data registers: b1 shifts right by 4 for RD0 read captures and
            // for FLUSH write nibbles (b1 is dead after a flush, so reusing
            // the pad-capture shift for it saves a mux level)
            if ((rd_samp && (state == S_RD0)) ||
                (state == S_FLUSH && wr_data && sck))
                b1 <= {sdin_m, b1[31:4]};
            else if (rshift)
                b1 <= {i_wen0 ? i_wdata0 : b1[0], b1[31:1]};

            // poll count init: only before the op is accepted (fop stays 1
            // across the whole op, including the inter-stage CS gaps)
            if (i_fop_req && (state == S_IDLE) && !fop)
                b2 <= 32'b0;
            else if (rd_samp && (state != S_RD0))
                b2 <= {sdin_m, b2[31:4]};
            else if (rshift)
                b2 <= {b2[0], b2[31:1]};
            else if ((state == S_FOP) && (fstg == F_POLL) && sck &&
                     (step == 5'd15) && fbusy)
                b2 <= b2 + 32'd1;                   // poll count


            if (i_wen0)
                dirty <= 1'b1;

            // flash register writes (dbus stable while the store waits)
            if (i_stat_we) begin
                wen <= i_dbus_dat[1];
                if (i_dbus_dat[0])       // W1C on the TIMEOUT bit
                    timeout <= 1'b0;
            end

            case (state)
            S_IDLE: begin
                sck <= 1'b0;
                if (gap != 0)
                    gap <= gap - 2'd1;
                else if (fop) begin     // resume next stage after a CS gap
                    state <= S_FOP;
                    step  <= 5'b0;
                end else if (dirty && (rf_go || i_dbus_req || i_ibus_req ||
                                       i_fop_req)) begin
                    state <= S_FLUSH;
                    step  <= 5'b0;
                end else if (rf_go) begin
                    state <= rf_ph ? S_RD1 : S_RD0;
                    step  <= 5'b0;
                end else if (i_fop_req) begin
                    state   <= S_FOP;
                    step    <= 5'b0;
                    fstg    <= F_WREN;
                    fdat    <= 1'b0;
                    fbusy   <= 1'b0;
                    fop     <= 1'b1;
                    timeout <= 1'b0;
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

            S_FOP: begin
                sck <= ~sck;
                if (!sck) begin
                    // SCK rises at step 15 of a poll: status bit0 = BUSY
                    if ((fstg == F_POLL) && (step == 5'd15))
                        fbusy <= sd_in[1];
                end else begin        // SCK falls
                    case (fstg)
                    F_WREN: begin     // cmd only, then CS-high gap
                        if (step == 5'd7) begin
                            sck   <= 1'b0;
                            gap   <= 2'd1;
                            step  <= 5'b0;
                            fstg  <= F_CMD;
                            state <= S_IDLE;
                        end else
                            step <= step + 5'd1;
                    end
                    F_CMD: begin
                        if (!fdat) begin
                            if (step == 5'd31) begin
                                if (i_fop_erase) begin  // erase done -> POLL
                                    sck   <= 1'b0;
                                    gap   <= 2'd1;
                                    step  <= 5'b0;
                                    fstg  <= F_POLL;
                                    state <= S_IDLE;
                                end else begin     // prog -> quad data phase
                                    fdat <= 1'b1;
                                    step <= 5'd14;
                                end
                            end else
                                step <= step + 5'd1;
                        end else if (step ==
                                     (5'd13 + {1'b0, wlen_eff, 1'b0})) begin
                            sck   <= 1'b0;
                            gap   <= 2'd1;
                            step  <= 5'b0;
                            fdat  <= 1'b0;
                            fstg  <= F_POLL;
                            state <= S_IDLE;
                        end else
                            step <= step + 5'd1;
                    end
                    default: begin    // F_POLL: cmd + 8 released clocks
                        if (step == 5'd15) begin
                            sck   <= 1'b0;
                            step  <= 5'b0;
                            state <= S_IDLE;
                            if (!fbusy)
                                fop <= 1'b0;          // done -> ack
                            else if (&b2[POLL_BITS-1:0]) begin
                                fop     <= 1'b0;
                                timeout <= 1'b1;      // done -> ack + TIMEOUT
                            end else
                                gap <= 2'd1;          // poll again
                        end else
                            step <= step + 5'd1;
                    end
                    endcase
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
