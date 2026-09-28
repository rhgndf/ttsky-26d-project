`default_nettype none
// Behavioral model of APS6404L QSPI PSRAM (cmd 0xEB read / 0x38 write).
// 128 KB, mirrored (spec: "RAM model 128 KB mirror"). Starts empty; firmware
// is in the flash model. Optional +RAMHEX preloads memory.
// Writes are byte-granular (1/2/4 bytes per transaction).
// A write covering byte address 0x1FEFC..0x1FEFF records tohost (1 = pass).
module psram_model #(
    parameter SIZE = 128 * 1024
) (
    input  wire       sck,
    input  wire       cs_n,
    input  wire [3:0] sd,        // resolved SD bus value
    input  wire [3:0] host_oe,   // DUT's sd_oe (for contention checks)
    output reg  [3:0] sd_drv,
    output reg  [3:0] sd_oe,
    output reg        error,
    output reg        tohost_flag,
    output reg [31:0] tohost_val
);

    reg [7:0] mem [0:SIZE-1];

    reg [1023:0] ramhex;
    integer dummy_cycles;
    integer ki;
    initial begin
        error       = 1'b0;
        tohost_flag = 1'b0;
        tohost_val  = 32'b0;
        sd_drv      = 4'b0;
        sd_oe       = 4'b0;
        for (ki = 0; ki < SIZE; ki = ki + 1) mem[ki] = 8'h00;
        if (!$value$plusargs("DUMMY=%d", dummy_cycles)) dummy_cycles = 6;
        if ($value$plusargs("RAMHEX=%s", ramhex)) $readmemh(ramhex, mem);
    end

    localparam S_CMD = 0, S_ADDR = 1, S_DUMMY = 2, S_RD = 3,
               S_WR = 4, S_IDLE = 5;
    integer state;
    integer cnt;
    integer outcnt;
    integer wnib;            // write nibbles received
    reg [7:0]  cmd;
    reg [23:0] addr;
    wire [23:0] maddr = addr & (SIZE - 1);
    reg [7:0]  wbyte;
    reg [31:0] tohost_acc;

    task err(input [255:0] msg);
        begin
            $display("PSRAM_ERROR: %0s (t=%0t)", msg, $time);
            error = 1'b1;
        end
    endtask

    function [3:0] rd_nib(input integer n);
        reg [7:0] b;
        begin
            b = mem[(maddr + (n >> 1)) & (SIZE-1)];
            rd_nib = n[0] ? b[3:0] : b[7:4];
        end
    endfunction

    // checked 1 ns after any drive change so zero-time decode transients at
    // clock edges (combinational sd_oe) don't false-trigger; real contention
    // persists for a full SCK half-period (>=10 ns)
    always @(sd_oe or host_oe) begin
        #1;
        if (sd_oe != 0 && host_oe != 0) err("SD contention: both sides driving");
    end

    always @(posedge sck) begin
        if (!cs_n) begin
            case (state)
            S_CMD: begin
                if (host_oe[3:1] != 0) err("host driving SD1-3 during cmd phase");
                cmd = {cmd[6:0], sd[0]};
                cnt = cnt + 1;
                if (cnt == 8) begin
                    cnt  = 0;
                    addr = 24'b0;
                    if (cmd == 8'hEB || cmd == 8'h38) state <= S_ADDR;
                    else begin
                        err("unknown command");
                        state <= S_IDLE;
                    end
                end
            end
            S_ADDR: begin
                if (host_oe != 4'hf) err("host oe!=f in addr phase");
                addr = {addr[19:0], sd};
                cnt  = cnt + 1;
                if (cnt == 6) begin
                    cnt = 0;
                    if (cmd == 8'hEB) begin
                        cnt   = dummy_cycles;
                        state = S_DUMMY;
                    end else begin
                        wnib  = 0;
                        state = S_WR;
                    end
                end
            end
            S_DUMMY: begin
                // host may drive 0 during the first 2 dummy clocks (mode bits
                // for the shared flash); must release for the last 4
                if (cnt <= 4 && host_oe != 0)
                    err("host driving SD during last 4 dummy cycles");
                cnt = cnt - 1;
                if (cnt == 0) begin
                    outcnt = 0;
                    state  = S_RD;
                end
            end
            S_RD: ;
            S_WR: begin
                if (host_oe != 4'hf) err("host oe!=f in write data");
                if (wnib[0] == 0) begin
                    wbyte[7:4] = sd;
                end else begin
                    wbyte[3:0] = sd;
                    mem[(maddr + (wnib >> 1)) & (SIZE-1)] = {wbyte[7:4], sd};
                    if ((maddr + (wnib >> 1)) == 24'h1FEFC) begin
                        tohost_val <= {24'b0, wbyte[7:4], sd};
                        tohost_flag <= 1'b1;
                    end
                end
                wnib = wnib + 1;
                if (wnib > 8) err("write longer than 4 bytes");
            end
            default: ;
            endcase
        end
    end

    always @(negedge sck) begin
        if (!cs_n && state == S_RD) begin
            if (outcnt < 8) begin
                sd_drv <= rd_nib(outcnt);
                sd_oe  <= 4'hf;
                outcnt <= outcnt + 1;
            end
        end else if (!cs_n && state != S_RD) begin
            sd_oe <= 4'b0;
        end
    end

    always @(posedge cs_n) begin
        sd_oe  <= 4'b0;
        outcnt <= 0;
        if (state == S_WR && wnib[0] == 1)
            err("write data phase: odd nibble count");
        if (state == S_RD && outcnt < 8 && outcnt != 0)
            err("read data phase cut short");
        state <= S_CMD;
        cnt   <= 0;
        wnib  <= 0;
        tohost_acc <= 32'b0;
    end

endmodule
