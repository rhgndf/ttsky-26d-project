`default_nettype none
// QSPI PSRAM controller (APS6404L-compatible, SPI-mode command 0xEB read / 0x38 write).
// Fixed 4-byte word transactions; 6 dummy cycles. Sub-word stores are merged
// upstream in the core — this engine always reads or writes a full word.
// SCK = clk/2: each SCK half-period is one clk; outputs change only when SCK goes low.
// Read data sampled on the clk edge that raises SCK.
module qspi_psram (
    input  wire        clk,
    input  wire        rst_n,
    // CPU-side bus
    input  wire        req,          // level; a transaction starts when seen in idle
    input  wire        wr,           // 1=write, 0=read
    input  wire [23:0] addr,         // byte address ([1:0] ignored)
    input  wire [31:0] wdata,
    output reg         ready,        // 1-clk pulse; rdata valid for reads
    output reg  [31:0] rdata,
    // QSPI pins
    output reg         sck,          // idle low
    output reg         cs_n,
    output reg  [3:0]  sd_out,
    output reg  [3:0]  sd_oe,
    input  wire [3:0]  sd_in
);

    localparam PH_IDLE  = 3'd0,  // CS_n high gap, waiting for req
               PH_CMD   = 3'd1,  // 8 bits serial on SD0
               PH_ADDR  = 3'd2,  // 6 nibbles quad
               PH_DUMMY = 3'd3,  // 6 dummy SCK cycles (reads only)
               PH_RDATA = 3'd4,  // 8 nibbles in
               PH_WDATA = 3'd5;  // 8 nibbles out

    reg [2:0]  phase;
    reg        sck_hi;             // 0: next clk raises SCK, 1: next clk lowers SCK
    reg  [3:0] cnt;                // items remaining in current phase
    reg  [2:0] csgap;
    reg  [7:0] cmdsh;              // serial cmd shift reg
    reg [23:0] addrsh;             // quad addr shift reg
    reg [31:0] wshift;             // write data store
    reg [31:0] rdshift;            // read data shift reg
    reg        is_wr;              // current transaction is a write
    wire _unused = &{1'b0, cmdsh[7], addr[1:0], 1'b0}; // cmdsh[7] consumed by shift-out

    // write data nibbles: b0hi,b0lo,b1hi,b1lo,... (low byte first, high nibble first)
    /* verilator lint_off UNUSED */
    function [3:0] wnib(input [31:0] d, input [3:0] i); // i[3] always 0 (indices 0..7)
        wnib = d[{i[2:1], ~i[0], 2'b0} +: 4];
    endfunction
    /* verilator lint_on UNUSED */

    task start_txn(input wr_i);
        begin
            cmdsh   <= wr_i ? 8'h38 : 8'hEB;
            cnt     <= 4'd8;
            cs_n    <= 1'b0;
            sck     <= 1'b0;
            sck_hi  <= 1'b0;
            sd_oe   <= 4'b0001;              // cmd on SD0 only
            sd_out  <= {3'b0, ~wr_i};        // cmd[7]
            phase   <= PH_CMD;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            phase  <= PH_IDLE;
            sck    <= 1'b0;
            cs_n   <= 1'b1;
            sd_oe  <= 4'b0;
            sd_out <= 4'b0;
            ready  <= 1'b0;
            sck_hi <= 1'b0;
            csgap  <= 3'd4;
        end else begin
            ready <= 1'b0;
            case (phase)
            // -------- idle: >=4 clk CS_n high before accepting a request
            PH_IDLE: begin
                sck   <= 1'b0;
                cs_n  <= 1'b1;
                sd_oe <= 4'b0;
                if (csgap != 0) begin
                    csgap <= csgap - 1;
                end else if (req) begin
                    addrsh <= addr;
                    wshift <= wdata;
                    is_wr  <= wr;
                    start_txn(wr);
                end
            end
            // -------- serial command, SD0 only
            PH_CMD: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin            // SCK falls: shift out next bit
                    cnt    <= cnt - 1;
                    cmdsh  <= {cmdsh[6:0], 1'b0};
                    sd_out <= {3'b0, cmdsh[6]};
                    if (cnt == 1) begin
                        cnt    <= 4'd6;
                        sd_oe  <= 4'b1111;
                        sd_out <= addrsh[23:20];
                        phase  <= PH_ADDR;
                    end
                end
            end
            // -------- quad address, MSB nibble first
            PH_ADDR: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt    <= cnt - 1;
                    addrsh <= {addrsh[19:0], 4'b0};
                    sd_out <= addrsh[19:16];
                    if (cnt == 1) begin
                        if (is_wr) begin
                            cnt    <= 4'd8;
                            sd_out <= wnib(wshift, 4'd0);
                            phase  <= PH_WDATA;
                        end else begin
                            cnt   <= 4'd6;
                            sd_oe <= 4'b0;
                            phase <= PH_DUMMY;
                        end
                    end
                end
            end
            // -------- dummy cycles (reads)
            PH_DUMMY: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt <= cnt - 1;
                    if (cnt == 1) begin
                        cnt     <= 4'd8;
                        rdshift <= 32'b0;
                        phase   <= PH_RDATA;
                    end
                end
            end
            // -------- quad read data: sample on the SCK-rising half-edge
            PH_RDATA: begin
                if (!sck_hi) rdshift <= {rdshift[27:0], sd_in};
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin          // a nibble completes at each falling edge
                    cnt <= cnt - 1;
                    if (cnt == 1) begin
                        // byte-swap: wire order b0 first -> rdata={b3,b2,b1,b0}
                        rdata <= {rdshift[7:0], rdshift[15:8], rdshift[23:16], rdshift[31:24]};
                        cs_n  <= 1'b1;
                        csgap <= 3'd4;
                        ready <= 1'b1;
                        phase <= PH_IDLE;
                    end
                end
            end
            // -------- quad write data
            PH_WDATA: begin
                sck    <= ~sck;
                sck_hi <= ~sck_hi;
                if (sck_hi) begin
                    cnt    <= cnt - 1;
                    sd_out <= wnib(wshift, 4'd9 - cnt);
                    if (cnt == 1) begin
                        cs_n  <= 1'b1;
                        sd_oe <= 4'b0;
                        csgap <= 3'd4;
                        ready <= 1'b1;
                        phase <= PH_IDLE;
                    end
                end
            end
            default: phase <= PH_IDLE;
            endcase
        end
    end

endmodule
