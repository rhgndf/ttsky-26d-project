`default_nettype none
// Minimal I2C slave model, 7-bit address 0x50, EEPROM-like:
//   write: [addr|W] then pointer byte, then data bytes (auto-increment)
//   read:  [addr|R] streams bytes from current pointer until master NACKs
//   NACKs a non-matching address; ACKs matching address and received bytes.
// Open-drain SDA drive: sda_drv=1 pulls the line low. No clock stretching.
// Discipline: bits captured on SCL rising edges; SDA drive changes while SCL low.
module i2c_slave_model (
    input  wire scl,
    input  wire sda,
    output reg  sda_drv,
    output reg  error
);

    localparam MY_ADDR = 7'h50;

    reg [7:0] mem [0:255];
    reg [7:0] ptr;
    reg [7:0] sh;          // receive shift register
    reg [7:0] txsh;        // transmit shift register
    reg [3:0] bcnt;
    reg       rw;          // address phase R/W bit (1=read)
    reg       addr_match;
    reg       got_ptr;
    reg       ack_bit;     // master ack sampled on last TX byte

    localparam S_IDLE  = 0,  // wait for START (or master NACK -> stop)
               S_ADDR  = 1,  // shifting in addr+r/w
               S_AACK  = 2,  // drive (or not) the address ACK
               S_RX    = 3,  // receiving a data byte
               S_RACK  = 4,  // drive ACK for received byte
               S_TX    = 5,  // transmitting a byte (MSB first)
               S_TXACK = 6;  // master sends ACK/NACK on 9th bit

    integer state;

    initial begin
        state = S_IDLE; bcnt = 0; sda_drv = 0; error = 0;
        sh = 0; txsh = 0; ptr = 0; rw = 0; addr_match = 0; got_ptr = 0; ack_bit = 0;
    end

    // START: SDA falls while SCL high. STOP: SDA rises while SCL high.
    always @(negedge sda) if (scl) begin
        state   <= S_ADDR;
        bcnt    <= 0;
        sh      <= 0;
        sda_drv <= 0;
        got_ptr <= 0;
    end
    always @(posedge sda) if (scl) begin
        state   <= S_IDLE;
        sda_drv <= 0;
    end

    // ---- bit capture on SCL rising edge
    always @(posedge scl) begin
        case (state)
        S_ADDR: begin
            sh   <= {sh[6:0], sda};
            bcnt <= bcnt + 1;
            if (bcnt == 4'd7) begin  // 8th bit just arrived; byte = {sh[6:0],sda}
                addr_match <= (sh[6:0] == MY_ADDR);
                rw         <= sda;
                state      <= S_AACK;
            end
        end
        S_RX: begin
            sh   <= {sh[6:0], sda};
            bcnt <= bcnt + 1;
            if (bcnt == 4'd7) begin
                if (!got_ptr) begin
                    ptr     <= {sh[6:0], sda};
                    got_ptr <= 1;
                end else begin
                    mem[ptr] <= {sh[6:0], sda};
                    ptr      <= ptr + 1;
                end
                state <= S_RACK;
            end
        end
        S_TX: begin
            txsh <= {txsh[6:0], 1'b0};
            bcnt <= bcnt + 1;
            if (bcnt == 4'd7) state <= S_TXACK;
        end
        S_TXACK: begin
            ack_bit <= sda;          // 0 = master ACK, keep sending
            if (sda == 1'b0) begin
                txsh <= mem[ptr]; ptr <= ptr + 1;
                bcnt <= 0; state <= S_TX;
            end else begin
                state <= S_IDLE;
            end
        end
        default: ;
        endcase
    end

    // ---- drive changes while SCL low (negedge or idle-low)
    always @(negedge scl) begin
        case (state)
        S_AACK: begin // ACK window = this low phase + next high
            if (addr_match) sda_drv <= 1'b1;
            // prepare next phase while driving ACK
            bcnt <= 0;
            if (!addr_match) begin
                state   <= S_IDLE;
            end else if (rw) begin
                txsh  <= mem[ptr]; ptr <= ptr + 1;
                state <= S_TX;
            end else begin
                sh    <= 0;
                state <= S_RX;
            end
        end
        S_RACK: begin // ACK the received byte
            sda_drv <= 1'b1;
            bcnt    <= 0;
            sh      <= 0;
            state   <= S_RX;
        end
        S_RX: begin
            sda_drv <= 1'b0;  // release after ACK completes
        end
        S_TX: begin
            sda_drv <= ~txsh[7]; // MSB first
        end
        default: sda_drv <= 1'b0;
        endcase
    end

endmodule
