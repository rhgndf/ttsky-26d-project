`default_nettype none
// Shared serial engine: SPI master (block 3) and I2C master (block 4) share one
// 8-bit shift register, bit counter, and clock divider — they cannot run at once.
//
// SPI (0x2000_0300), mode 0, MSB first:
//   0x00 DATA: write = start 8-bit full-duplex transfer; read = last RX byte
//   0x04 CTRL/STATUS: [0] busy (ro), [1] CS_n level (rw, reset 1)
//   0x08 DIV: shared divider [7:0], reset 124
// I2C (0x2000_0400) master, open drain:
//   0x00 DATA: write = stage TX byte (for WRITE cmd); read = RX byte (after READ)
//   0x04 CMD (write, ignored if busy): [0] START, [1] WRITE, [2] READ,
//        [3] send NACK after READ, [4] STOP — executed in that order, any subset.
//        read = STATUS: [0] busy, [1] nack received on last WRITE.
// SPI SCK half period = I2C quarter period = DIV+1 clk.
module serial (
    input  wire        clk,
    input  wire        rst_n,
    // SPI register port (block 3; addr[3:2])
    input  wire        spi_req,
    input  wire [1:0]  spi_regsel,
    input  wire        spi_wr,
    input  wire [31:0] wdata,
    output reg  [31:0] spi_rdata,
    // I2C register port (block 4; addr[3:2])
    input  wire        i2c_req,
    input  wire [1:0]  i2c_regsel,
    input  wire        i2c_wr,
    output reg  [31:0] i2c_rdata,
    // SPI pins
    output reg         spi_sck,
    output reg         spi_mosi,
    input  wire        spi_miso,
    output reg         spi_csn,
    // I2C pins (open drain: oe=1 drives the line low)
    output reg         i2c_sda_oe,
    output reg         i2c_scl_oe,
    input  wire        sda_in,
    input  wire        scl_in
);

    reg  [7:0] div;
    reg  [7:0] shift;       // shared TX/RX shift register
    reg  [3:0] bitcnt;      // bits remaining in byte
    reg  [7:0] divcnt;
    reg        busy;
    reg        nack;        // ACK level sampled after last WRITE
    reg  [4:0] i2c_cmd;     // pending I2C command bits
    reg        rd_op;       // current I2C byte op is a read
    reg  [3:0] sstate;

    localparam ST_IDLE = 4'd0,
        ST_SPI   = 4'd1,   // SPI toggle (both half periods)
        ST_NEXT  = 4'd2,   // I2C: dispatch next pending cmd bit
        ST_STA   = 4'd3,   // I2C START: sda low while scl high
        ST_STA2  = 4'd4,   // I2C START: scl falls
        ST_BITL  = 4'd5,   // I2C bit: scl low phase (set/release sda)
        ST_BITH  = 4'd6,   // I2C bit: scl high phase (sample on read)
        ST_ACKL  = 4'd7,   // I2C 9th: scl low (ack/nack or release)
        ST_ACKH  = 4'd8,   // I2C 9th: scl high (sample ack)
        ST_STP   = 4'd9,   // I2C STOP: scl rises while sda low
        ST_STP2  = 4'd10;  // I2C STOP: sda rises

    wire _unused = &{1'b0, scl_in, wdata[31:8], 1'b0};

    always @(*) begin
        case (spi_regsel)
        2'd1:    spi_rdata = {30'b0, spi_csn, busy};
        2'd2:    spi_rdata = {24'b0, div};
        default: spi_rdata = {24'b0, shift};
        endcase
    end
    always @(*) begin
        case (i2c_regsel)
        2'd1:    i2c_rdata = {30'b0, nack, busy};
        default: i2c_rdata = {24'b0, shift};
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            div <= 8'd124;
            shift <= 8'b0; bitcnt <= 4'd0; divcnt <= 8'b0;
            busy <= 1'b0; nack <= 1'b0; i2c_cmd <= 5'b0; rd_op <= 1'b0;
            sstate <= ST_IDLE;
            spi_sck <= 1'b0; spi_mosi <= 1'b0; spi_csn <= 1'b1;
            i2c_sda_oe <= 1'b0; i2c_scl_oe <= 1'b0;
        end else begin
            // ---- register writes (DIV, CS_n and staging take effect even while idle)
            if (spi_req && spi_wr) begin
                case (spi_regsel)
                2'd0: if (!busy) begin
                    shift    <= wdata[7:0];
                    bitcnt   <= 4'd8;
                    busy     <= 1'b1;
                    spi_sck  <= 1'b0;
                    spi_mosi <= wdata[7];
                    divcnt   <= div;
                    sstate   <= ST_SPI;
                end
                2'd1: spi_csn <= wdata[1];
                2'd2: div <= wdata[7:0];
                default: ;
                endcase
            end
            if (i2c_req && i2c_wr) begin
                case (i2c_regsel)
                2'd0: shift <= wdata[7:0]; // stage TX byte
                2'd1: if (!busy) begin     // CMD
                    i2c_cmd <= wdata[4:0];
                    busy    <= 1'b1;
                    nack    <= 1'b0;
                    divcnt  <= div;
                    sstate  <= ST_NEXT;
                end
                default: ;
                endcase
            end

            // ---- shared divider engine
            if (divcnt != 0) begin
                divcnt <= divcnt - 1;
            end else case (sstate)
            ST_IDLE: ;
            ST_SPI: begin // one SCK half-period per visit
                divcnt <= div;
                if (!spi_sck) begin        // raise SCK, sample MISO
                    spi_sck <= 1'b1;
                    shift   <= {shift[6:0], spi_miso};
                end else begin             // lower SCK, put next bit out
                    spi_sck  <= 1'b0;
                    spi_mosi <= shift[7];  // shift already advanced
                    bitcnt   <= bitcnt - 1;
                    if (bitcnt == 4'd1) begin
                        busy   <= 1'b0;
                        sstate <= ST_IDLE;
                    end
                end
            end
            // I2C command dispatch — order: START, WRITE, READ, STOP
            ST_NEXT: begin
                divcnt <= div;
                if (i2c_cmd[0]) begin          // START
                    i2c_cmd[0]  <= 1'b0;
                    i2c_sda_oe  <= 1'b1;       // SDA low while SCL high
                    i2c_scl_oe  <= 1'b0;
                    sstate      <= ST_STA;
                end else if (i2c_cmd[1]) begin // WRITE
                    i2c_cmd[1] <= 1'b0;
                    rd_op      <= 1'b0;
                    bitcnt     <= 4'd8;
                    sstate     <= ST_BITL;
                end else if (i2c_cmd[2]) begin // READ
                    i2c_cmd[2] <= 1'b0;
                    rd_op      <= 1'b1;
                    bitcnt     <= 4'd8;
                    sstate     <= ST_BITL;
                end else if (i2c_cmd[4]) begin // STOP
                    i2c_cmd[4] <= 1'b0;
                    i2c_sda_oe <= 1'b1;        // SDA low with SCL low
                    sstate     <= ST_STP;
                end else begin
                    busy   <= 1'b0;
                    sstate <= ST_IDLE;
                end
            end
            ST_STA:  begin i2c_scl_oe <= 1'b1; divcnt <= div; sstate <= ST_STA2; end
            ST_STA2: begin divcnt <= div; sstate <= ST_NEXT; end
            ST_BITL: begin // SCL low: set data bit for write, release for read
                i2c_sda_oe <= rd_op ? 1'b0 : ~shift[7];
                divcnt <= div;
                sstate <= ST_BITH;
            end
            ST_BITH: begin // SCL high: sample on read; then lower SCL
                i2c_scl_oe <= 1'b0;
                if (rd_op) shift <= {shift[6:0], sda_in};
                else       shift <= {shift[6:0], 1'b0};
                divcnt <= div;
                if (bitcnt == 4'd1) sstate <= ST_ACKL;
                else begin
                    bitcnt   <= bitcnt - 1;
                    i2c_scl_oe <= 1'b1;  // lower SCL for next bit
                    sstate   <= ST_BITL;
                end
            end
            ST_ACKL: begin // 9th bit, SCL low: write releases, read drives ACK/NACK
                i2c_sda_oe <= rd_op ? i2c_cmd[3] : 1'b0;
                i2c_scl_oe <= 1'b0;
                divcnt <= div;
                sstate <= ST_ACKH;
            end
            ST_ACKH: begin // 9th bit, SCL high: write samples ACK level
                if (!rd_op) nack <= sda_in;
                i2c_scl_oe <= 1'b1;   // SCL low again
                divcnt <= div;
                sstate <= ST_NEXT;
            end
            ST_STP:  begin i2c_scl_oe <= 1'b0; divcnt <= div; sstate <= ST_STP2; end // SCL high
            ST_STP2: begin i2c_sda_oe <= 1'b0; divcnt <= div; sstate <= ST_NEXT; end // SDA rises
            default: begin sstate <= ST_IDLE; busy <= 1'b0; end
            endcase
        end
    end

endmodule
