`default_nettype none
// Shared QSPI engine for TT QSPI Pmod: CS0 = W25Q128 flash, CS1 = APS6404 PSRAM.
// SCK = clk/2, SPI mode 0. Outputs change on the clk edge that lowers SCK;
// inputs are sampled on the clk edge that raises SCK.
//
// Transaction (one op at a time):
//   CS low, cmd 8b serial on SD0, addr 6 nibbles quad, then:
//   - read (0xEB): 6 wait clocks — drive 0 quad for first 2 (flash mode bits
//     = 0x00, never continuous mode), release for last 4; then 8 nibbles in.
//   - write (0x38): wlen*2 nibbles (1, 2 or 4 bytes) straight after address.
// CS high >= 2 clk between transactions.
//
// Client view: assert op_req with op_we/op_cs/op_addr(/op_wdata+op_wofs+op_wlen)
// held until op_done; op_rdata valid with op_done.
module qspi_ctrl (
    input  wire        clk,
    input  wire        rst_n,
    // op interface
    input  wire        op_req,
    input  wire        op_we,
    input  wire        op_cs,        // 0 = CS0 flash, 1 = CS1 PSRAM
    input  wire [23:0] op_addr,
    input  wire [31:0] op_wdata,
    input  wire [1:0]  op_wofs,      // first byte lane for writes
    input  wire [2:0]  op_wlen,      // write length in bytes (1/2/4)
    output wire [31:0] op_rdata,
    output reg         op_done,
    output wire        op_ready,   // idle and CS gap elapsed
    // pads
    output reg         cs0_n,
    output reg         cs1_n,
    output reg         sck,
    output reg  [3:0]  sd_out,
    output reg  [3:0]  sd_oe,
    input  wire [3:0]  sd_in
);

    localparam PH_IDLE = 0, PH_CMD = 1, PH_ADDR = 2, PH_WAIT = 3,
               PH_RDATA = 4, PH_WDATA = 5, PH_DONE = 6;

    reg  [2:0]  phase;
    reg         sck_hi;     // 0: next clk raises SCK, 1: next clk lowers SCK
    reg  [3:0]  cnt;        // items remaining in current phase
    reg  [1:0]  gap;        // CS high gap counter
    reg [31:0]  dshift;     // read data capture (left-shifts nibbles in)
    reg [23:0]  a_lat;      // latched address (client adr may shift mid-txn)
    reg [31:0]  w_lat;      // latched write data
    reg         is_wr;
    reg  [1:0]  wofs;
    reg  [2:0]  wlen;

    // Every sck_hi edge LAUNCHES the next item; cnt = items still to launch
    // after the currently-driven one (i.e. next index = total - cnt).
    // CMD: next bit index cidx = 8-cnt+... bit launched = cmd[cnt-2] for cnt>=2
    wire       cmd_bit = is_wr ? ((8'h38 >> (cnt - 2)) & 8'd1) != 0
                               : ((8'hEB >> (cnt - 2)) & 8'd1) != 0;
    // ADDR: nibble launched = aidx = 6-cnt (entry cnt=5 launches nibble 1)
    wire [3:0] aidx = 4'd6 - cnt;
    wire [3:0]  adrnib = a_lat[(4'd5 - aidx) * 4 +: 4];
    // WDATA: nibble launched = widx = wlen*2-cnt, covering lanes
    // wofs..wofs+wlen-1 (client data is lane-placed like sel; the byte offset
    // is also folded into the latched address).
    wire [4:0]  widx_w = {1'b0, wlen, 1'b0} - {1'b0, cnt};
    wire [3:0]  widx = widx_w[3:0];
    wire [3:0]  lane = {2'b0, wofs} + {1'b0, widx[3:1]};
    wire [7:0]  laneb = w_lat[lane * 8 +: 8];
    wire [3:0] wdatanib = widx[0] ? laneb[3:0] : laneb[7:4];

    // read data: rdata = byte-reversed dshift (wire order b0hi,b0lo,...)
    assign op_rdata = {dshift[7:0], dshift[15:8], dshift[23:16], dshift[31:24]};
    assign op_ready = (phase == PH_IDLE) && (gap == 0);

    always @(posedge clk) begin
        if (!rst_n) begin
            phase  <= PH_IDLE;
            sck    <= 1'b0;  sck_hi <= 1'b0;
            cs0_n  <= 1'b1;  cs1_n  <= 1'b1;
            sd_oe  <= 4'b0;  sd_out <= 4'b0;
            cnt    <= 4'b0;  gap    <= 2'b0;
            dshift <= 32'b0;
            is_wr  <= 1'b0;
            wofs   <= 2'b0;  wlen   <= 3'b0;
            op_done <= 1'b0;
        end else begin
            op_done <= 1'b0;
            case (phase)
            PH_IDLE: begin
                sck   <= 1'b0;
                cs0_n <= 1'b1; cs1_n <= 1'b1;
                sd_oe <= 4'b0;
                if (gap != 0) gap <= gap - 1;
                else if (op_req) begin
                    is_wr  <= op_we;
                    // sub-word writes: client addr is word-aligned, the byte
                    // offset is in op_wofs; store data stays right-justified
                    a_lat  <= op_addr + {22'b0, op_we ? op_wofs : 2'b00};
                    w_lat  <= op_wdata;
                    wofs   <= op_wofs;
                    wlen   <= op_we ? op_wlen : 3'd0;
                    cnt    <= 4'd8;
                    sck_hi <= 1'b0;
                    sd_oe  <= 4'b0001;                    // cmd on SD0 only
                    sd_out <= {3'b0, ~op_we};             // cmd[7]=0 reads/0xEB? 0xEB[7]=1,0x38[7]=0
                    if (op_cs) cs1_n <= 1'b0; else cs0_n <= 1'b0;
                    phase  <= PH_CMD;
                end
            end
            PH_CMD: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin                // SCK falls: next item
                    if (cnt == 1) begin          // all 8 cmd bits done; launch
                        cnt    <= 4'd5;          // addr nibble 0, 5 remain
                        sd_oe  <= 4'b1111;
                        sd_out <= a_lat[23:20];
                        phase  <= PH_ADDR;
                    end else begin
                        cnt    <= cnt - 1;
                        sd_out <= {3'b0, cmd_bit};
                    end
                end
            end
            PH_ADDR: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt    <= cnt - 1;
                    sd_out <= adrnib;
                    if (cnt == 1) begin
                        if (is_wr) begin
                            cnt   <= op_wlen[2:0] * 2; // 2/4/8 nibbles
                            phase <= PH_WDATA;      // sd_oe stays 4'hf
                        end else begin
                            cnt   <= 4'd7;          // 7 wait sck periods
                            phase <= PH_WAIT;       // sd_oe stays f for mode
                        end
                    end
                end
            end
            // 8 sck periods = 7 wait posedges (1 entry + 2 mode + 4 dummy):
            // drive 0 quad for the two mode clocks (periods 2-3), then release
            PH_WAIT: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt    <= cnt - 1;
                    sd_out <= 4'b0;
                    if (cnt == 4'd5) sd_oe <= 4'b0;  // release after 2 driven
                    if (cnt == 1) begin
                        cnt   <= 4'd8;
                        phase <= PH_RDATA;
                    end
                end
            end
            PH_RDATA: begin
                if (!sck_hi) dshift <= {dshift[27:0], sd_in}; // sample on rising
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt <= cnt - 1;
                    if (cnt == 1) phase <= PH_DONE; // last nibble needs its posedge
                end
            end
            PH_WDATA: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt    <= cnt - 1;
                    sd_out <= wdatanib;
                    if (cnt == 1) phase <= PH_DONE; // last nibble needs a posedge
                end
            end
            PH_DONE: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cs0_n <= 1'b1; cs1_n <= 1'b1;
                    sd_oe <= 4'b0;
                    gap   <= 2'd2;
                    op_done <= 1'b1;
                    phase <= PH_IDLE;
                end
            end
            default: phase <= PH_IDLE;
            endcase
        end
    end

    wire _unused = &{1'b0, widx_w[4], 1'b0};

endmodule
`default_nettype wire
