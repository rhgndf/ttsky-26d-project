`default_nettype none
// Behavioral model of W25Q128 QSPI flash (read-only in this SoC: cmd 0xEB only).
// >=1 MB image, loaded via +HEX=<path> plusarg ($readmemh, byte-wide).
// Protocol checks on `error` / $display "FLASH_ERROR":
//  - any command other than 0xEB (writes must never happen)
//  - host not driving quad during cmd/addr phases as required
//  - mode bits (first 2 wait-clock nibbles) = 0bxx10 -> continuous mode, illegal
//  - host driving during the last 4 wait clocks or the read data phase
//  - read data phase cut short
module flash_model #(
    parameter SIZE = 1024 * 1024
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
    initial begin
        error  = 1'b0;
        sd_drv = 4'b0;
        sd_oe  = 4'b0;
        for (ki = 0; ki < SIZE; ki = ki + 1) mem[ki] = 8'h00;
        if ($value$plusargs("HEX=%s", hexfile)) $readmemh(hexfile, mem);
    end

    wire [23:0] maddr = addr & (SIZE - 1);

    localparam S_CMD = 0, S_ADDR = 1, S_MODE = 2, S_DUMMY = 3,
               S_RD = 4, S_IDLE = 5;
    integer state;
    integer cnt;
    integer outcnt;
    reg [7:0]  cmd;
    reg [23:0] addr;
    reg [7:0]  mode;          // mode bits from first 2 wait clocks

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

    always @(*) begin
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
                    if (cmd == 8'hEB) state <= S_ADDR;
                    else begin
                        err("write/unknown command on flash (read-only)");
                        state <= S_IDLE;
                    end
                end
            end
            S_ADDR: begin
                if (host_oe != 4'hf) err("host oe!=f in addr phase");
                addr = {addr[19:0], sd};
                cnt  = cnt + 1;
                if (cnt == 6) begin
                    cnt   = 2;
                    mode  = 8'b0;
                    state = S_MODE;
                end
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
            S_RD: ;  // model drives on negedge
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
        if (state == S_RD && outcnt < 8 && outcnt != 0)
            err("read data phase cut short");
        state <= S_CMD;
        cnt   <= 0;
    end

endmodule
