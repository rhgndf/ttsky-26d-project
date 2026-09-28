`default_nettype none
// Behavioral model of the QSPI PSRAM (APS6404L SPI mode, cmd 0xEB read / 0x38 write).
// 256 KB image, loaded via +HEX=<path> plusarg ($readmemh, byte-wide).
// Checks protocol violations and flags them on `error` / $display "PSRAM_ERROR".
// A completed write to word address 0x3FF00 records `tohost` (1 = pass, else fail code).
module psram_model #(
    parameter SIZE = 256 * 1024
) (
    input  wire       sck,
    input  wire       cs_n,
    input  wire [3:0] sd,        // resolved SD bus value
    input  wire [3:0] host_oe,   // DUT's sd_oe (for contention checks)
    output reg  [3:0] sd_drv,    // value model drives
    output reg  [3:0] sd_oe,     // which bits model drives
    output reg        error,     // sticky protocol-error flag
    output reg        tohost_flag,
    output reg [31:0] tohost_val
);

    reg [7:0] mem [0:SIZE-1];

    // plusargs / init
    reg [1023:0] hexfile;
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
        if ($value$plusargs("HEX=%s", hexfile)) begin
            $readmemh(hexfile, mem);
        end
    end

    // physical RAM aliases high addresses (e.g. the 0xFFFF80 regfile window)
    wire [23:0] maddr = addr & (SIZE - 1);

    localparam S_CMD   = 0,
               S_ADDR  = 1,
               S_DUMMY = 2,
               S_RD    = 3,
               S_WR    = 4,
               S_IDLE  = 5; // cmd error: wait for CS_n high
    integer state;
    integer cnt;             // bits/nibbles remaining
    integer outcnt;          // nibbles already driven (read data phase)
    reg [7:0]  cmd;
    reg [23:0] addr;
    reg [31:0] wshift;       // write-data collector (first nibble -> [31:28])

    task err(input [255:0] msg);
        begin
            $display("PSRAM_ERROR: %0s (t=%0t)", msg, $time);
            error = 1'b1;
        end
    endtask

    // byte to read next for read data: byte (outcnt>>1), hi nibble first
    function [3:0] rd_nib(input integer i);
        reg [7:0] b;
        begin
            b = mem[maddr + (i >> 1)];
            rd_nib = i[0] ? b[3:0] : b[7:4];
        end
    endfunction

    initial begin
        state = S_CMD;
        cnt   = 0;
        outcnt= 0;
        cmd   = 8'h00;
        addr  = 24'h0;
    end

    // contention: model may never drive while host drives
    always @(*) begin
        if (sd_oe != 0 && host_oe != 0) err("SD contention: both sides driving");
    end

    // capture on SCK rising edge while CS low
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
`ifdef PSRAM_DEBUG
                    $display("PSRAM: cmd=%02x t=%0t", cmd, $time);
`endif
                    if (cmd == 8'hEB)      state <= S_ADDR;
                    else if (cmd == 8'h38) state <= S_ADDR;
                    else begin
                        err("unknown command");
                        state <= S_IDLE;
                    end
                end
            end
            S_ADDR: begin
                if (host_oe != 4'hf) begin
                    $display("PSRAM_ERROR: host oe=%b in addr phase (t=%0t)", host_oe, $time);
                    error = 1'b1;
                end
                addr = {addr[19:0], sd};
                cnt  = cnt + 1;
                if (cnt == 6) begin
                    cnt = 0;
                    if (cmd == 8'hEB) begin
                        cnt   = dummy_cycles;
                        state = S_DUMMY;
                    end else begin
                        cnt    = 8;
                        wshift = 32'b0;
                        state  = S_WR;
                    end
                end
            end
            S_DUMMY: begin
                if (host_oe != 0) err("host driving SD during dummy cycles");
                cnt = cnt - 1;
                if (cnt == 0) begin
                    cnt    = 8;
                    outcnt = 0;
                    state  = S_RD;
                end
            end
            S_RD: begin
                // model drives; nothing to capture
            end
            S_WR: begin
                if (host_oe != 4'hf) begin
                    $display("PSRAM_ERROR: host oe=%b in write data (t=%0t)", host_oe, $time);
                    error = 1'b1;
                end
                wshift = {wshift[27:0], sd};
                cnt    = cnt - 1;
                if (cnt == 0) begin
                    // complete word: byte order b0..b3 = nibbles 0..7
                    begin : wr_done
                        reg [31:0] val;
                        val = wshift;
                        // val[31:24]=b0 ... [7:0]=b3 (b0 = byte at addr)
                        mem[maddr+0] = val[31:24];
                        mem[maddr+1] = val[23:16];
                        mem[maddr+2] = val[15:8];
                        mem[maddr+3] = val[7:0];
                        if (maddr == 24'h03FF00) begin
                            tohost_val  <= {val[7:0], val[15:8], val[23:16], val[31:24]};
                            tohost_flag <= 1'b1;
                        end
                    end
                    cnt   = 0;
                    state = S_IDLE; // expect CS_n high; check in cs_n block
                end
            end
            default: ;
            endcase
        end
    end

    // drive read data on SCK falling edge (after last dummy falling edge)
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

    // CS_n rising edge: validate transaction end
    always @(posedge cs_n) begin
        sd_oe <= 4'b0;
        outcnt <= 0;
        if (state == S_WR && cnt != 0)
            err("write data phase length != 4 bytes");
        if (state == S_RD && outcnt < 8 && outcnt != 0)
            err("read data phase cut short");
        // restart protocol
        state <= S_CMD;
        cnt   <= 0;
    end

endmodule
