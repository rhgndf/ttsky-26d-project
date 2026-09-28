`default_nettype none
// Behavioral model of W25Q128 QSPI flash.
// >=1 MB image, loaded via +HEX=<path> plusarg ($readmemh, byte-wide).
// Commands: 0xEB quad read (mode bits must not be 0bxx10), 0x06 WREN,
// 0x32 quad page program (WEL-gated, AND semantics), 0x20 sector erase
// (WEL-gated, 4 KiB -> 0xFF), 0x05 read status ({6'b0,WEL,BUSY} on SD1,
// MSB first, repeated while CS is low). BUSY stays set for BUSY_POLLS
// polls after program/erase, or forever with +STUCK_BUSY.
// Protocol checks on `error` / $display "FLASH_ERROR":
//  - unknown command; program/erase without WEL or while BUSY
//  - wrong host drive (oe) per phase; SD contention; cut phases
module flash_model #(
    parameter SIZE = 1024 * 1024,
    parameter BUSY_POLLS = 3
) (
    input  wire       sck,
    input  wire       cs_n,
    input  wire [3:0] sd,        // resolved SD bus value
    input  wire [3:0] host_oe,   // DUT's sd_oe (for contention checks)
    output reg  [3:0] sd_drv,
    output reg  [3:0] sd_oe,
    output reg        error
);

    reg [7:0] mem [0:SIZE-1];

    reg [1023:0] hexfile;
    integer ki;
    integer stuck_busy;
    initial begin
        error  = 1'b0;
        sd_drv = 4'b0;
        sd_oe  = 4'b0;
        wel    = 1'b0;
        busy   = 1'b0;
        busy_n = 0;
        for (ki = 0; ki < SIZE; ki = ki + 1) mem[ki] = 8'h00;
        if ($value$plusargs("HEX=%s", hexfile)) $readmemh(hexfile, mem);
        stuck_busy = $test$plusargs("STUCK_BUSY");
    end

    localparam S_CMD = 0, S_ADDR = 1, S_MODE = 2, S_DUMMY = 3,
               S_RD = 4, S_IDLE = 5, S_SADDR = 6, S_WDATA = 7, S_STAT = 8;
    integer state;
    integer cnt;
    integer outcnt;
    reg [7:0]  cmd;
    reg [23:0] addr;
    wire [23:0] maddr = addr & (SIZE - 1);
    reg [7:0]  mode;          // mode bits from first 2 wait clocks
    reg [31:0] wdat;          // program data nibble accumulator
    integer    wnib;          // nibbles received so far
    reg        wel, busy;
    integer    busy_n;
    integer    i, b;

    task err(input [255:0] msg);
        begin
            $display("FLASH_ERROR: %0s (t=%0t)", msg, $time);
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

    wire [7:0] stat = {6'b0, wel, busy | (stuck_busy != 0)};
    wire [3:0] stat_bit = {2'b0, stat[7 - (outcnt & 7)], 1'b0};

    // see psram_model: 1 ns settle so zero-time decode transients don't count
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
                    case (cmd)
                    8'hEB: state <= S_ADDR;
                    8'h06: begin                   // WREN
                        wel   <= 1'b1;
                        state <= S_IDLE;           // CS must rise next
                    end
                    8'h20, 8'h32: begin            // ERASE / PROG
                        if (!wel) err("program/erase without WREN");
                        if (busy) err("program/erase while BUSY");
                        state <= S_SADDR;
                    end
                    8'h05: begin                   // READ STATUS
                        outcnt = 0;
                        state  <= S_STAT;
                    end
                    default: begin
                        err("unknown command on flash");
                        state <= S_IDLE;
                    end
                    endcase
                end
            end
            S_ADDR: begin   // 0xEB: 24-bit quad address
                if (host_oe != 4'hf) err("host oe!=f in addr phase");
                addr = {addr[19:0], sd};
                cnt  = cnt + 1;
                if (cnt == 6) begin
                    cnt   = 2;
                    mode  = 8'b0;
                    state = S_MODE;
                end
            end
            S_SADDR: begin  // 0x20/0x32: 24-bit serial address on SD0
                if (host_oe != 4'h1) err("host oe!=1 in serial addr phase");
                addr = {addr[22:0], sd[0]};
                cnt  = cnt + 1;
                if (cnt == 24) begin
                    cnt = 0;
                    if (cmd == 8'h32) begin
                        wnib  = 0;
                        state = S_WDATA;
                    end else begin                 // erase: sector -> 0xFF
                        // addr was just blocking-updated: use it, not maddr
                        for (b = 0; b < 4096; b = b + 1)
                            mem[((addr & ~24'hFFF) + b) & (SIZE-1)] = 8'hFF;
                        wel    <= 1'b0;
                        busy   <= 1'b1;
                        busy_n <= BUSY_POLLS;
                        state  = S_IDLE;
                    end
                end
            end
            S_WDATA: begin  // 0x32: quad data nibbles until CS rises
                if (host_oe != 4'hf) err("host oe!=f in write data phase");
                wdat = {wdat[27:0], sd};
                wnib = wnib + 1;
            end
            S_MODE: begin   // 2 wait clocks: host drives mode bits M7-0
                if (host_oe != 4'hf) err("host not driving mode bits");
                mode = {mode[3:0], sd};
                cnt  = cnt - 1;
                if (cnt == 0) begin
                    if (mode[5:4] == 2'b10)
                        err("continuous-read mode bits 0bxx10");
                    cnt   = 4;
                    state = S_DUMMY;
                end
            end
            S_DUMMY: begin  // 4 wait clocks: bus released
                if (host_oe != 0) err("host driving during dummy clocks");
                cnt = cnt - 1;
                if (cnt == 0) begin
                    outcnt = 0;
                    state  = S_RD;
                end
            end
            S_STAT: begin   // 0x05: host must stay released
                if (host_oe != 0) err("host driving during status read");
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
        end else if (!cs_n && state == S_STAT) begin
            sd_drv <= stat_bit;
            sd_oe  <= 4'b0010;      // status on SD1 only
            outcnt <= outcnt + 1;
        end else if (!cs_n) begin
            sd_oe <= 4'b0;
        end
    end

    always @(posedge cs_n) begin
        sd_oe  <= 4'b0;
        outcnt <= 0;
        if (state == S_RD && outcnt < 8 && outcnt != 0)
            err("read data phase cut short");
        if (state == S_WDATA) begin
            if (wnib == 0 || (wnib & 1))
                err("program data not a whole number of bytes");
            for (i = 0; i < (wnib >> 1); i = i + 1)
                mem[(maddr + i) & (SIZE-1)] =
                    mem[(maddr + i) & (SIZE-1)] &
                    wdat[8*((wnib >> 1) - 1 - i) +: 8];   // AND-program
            wel    <= 1'b0;
            busy   <= 1'b1;
            busy_n <= BUSY_POLLS;
        end
        if (state == S_STAT && busy_n > 0) begin
            busy_n = busy_n - 1;
            if (busy_n == 0) busy <= 1'b0;
        end
        state <= S_CMD;
        cnt   <= 0;
    end

endmodule
`default_nettype wire
