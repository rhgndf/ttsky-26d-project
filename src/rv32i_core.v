`default_nettype none
// RV32I + minimal Zicsr multi-cycle core. Area-first: shared adder, serial shifter,
// regfile with a single async read port (rs1/rs2 read in consecutive cycles).
// Bus: picorv32-style (mem_valid held until mem_ready pulse).
module rv32i_core (
    input  wire        clk,
    input  wire        rst_n,
    output reg         mem_valid,
    input  wire        mem_ready,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,
    input  wire        irq_timer,
    input  wire        irq_ext
);

    localparam ST_IRQ    = 5'd0,   // instruction boundary: interrupt check, start fetch
               ST_FETCH  = 5'd1,   // wait for instruction word
               ST_RS1    = 5'd2,   // capture rs1
               ST_RS2    = 5'd3,   // capture rs2
               ST_EXEC   = 5'd4,   // dispatch on opcode
               ST_ALUWB  = 5'd5,   // shared-adder result -> res
               ST_SHIFT  = 5'd6,   // serial shift loop
               ST_BR     = 5'd7,   // branch compare (adder holds rs1-rs2)
               ST_JT     = 5'd8,   // jump target check (adder holds target)
               ST_LSADDR = 5'd9,   // load/store effective-address check + issue
               ST_MEM    = 5'd10,  // bus wait
               ST_LDEXT  = 5'd11,  // load extract + sign extend
               ST_CSR    = 5'd12,
               ST_MRET   = 5'd13,
               ST_TRAP   = 5'd14,
               ST_WB     = 5'd15,
               ST_BRT    = 5'd16,  // branch: adder holds pc+imm_b
               ST_BRPC   = 5'd17;  // branch not taken: adder holds pc+4

    reg [4:0] state;
    reg [31:0] instr;

    // ---------------- regfile: x1..x31, no reset, single async read port
    reg [31:0] xregs [1:31];
    reg  [4:0] rf_raddr;
    wire [31:0] rf_rdata = (rf_raddr == 0) ? 32'b0 : xregs[rf_raddr];

    // ---------------- CSRs
    reg        csr_mie;        // mstatus.MIE  (bit 3)
    reg        csr_mpie;       // mstatus.MPIE (bit 7)
    reg        csr_mtie;       // mie.MTIE     (bit 7)
    reg        csr_meie;       // mie.MEIE     (bit 11)
    reg [31:0] csr_mtvec;
    reg [31:0] csr_mscratch;
    reg [31:0] csr_mepc;
    reg        csr_mcause_int;
    reg  [3:0] csr_mcause_code;

    reg [31:0] csr_rdata;
    reg        csr_hit;
    always @(*) begin
        csr_rdata = 32'b0;
        csr_hit   = 1'b1;
        case (instr[31:20])
            12'h300: csr_rdata = {24'b0, csr_mpie, 3'b011, csr_mie, 3'b0}; // mstatus: MPP=11
            12'h301: csr_rdata = 32'h4000_0100;                          // misa: MXL=32, I
            12'h304: csr_rdata = {20'b0, csr_meie, 3'b0, csr_mtie, 7'b0};// mie
            12'h305: csr_rdata = csr_mtvec;
            12'h340: csr_rdata = csr_mscratch;
            12'h341: csr_rdata = {csr_mepc[31:2], 2'b00};
            12'h342: csr_rdata = {csr_mcause_int, 27'b0, csr_mcause_code};
            12'h343: csr_rdata = 32'b0;                                  // mtval RO 0
            12'h344: csr_rdata = {20'b0, irq_ext, 3'b0, irq_timer, 7'b0};// mip RO
            12'hF14: csr_rdata = 32'b0;                                  // mhartid RO 0
            default: csr_hit = 1'b0;                                     // reads 0, writes ignored
        endcase
    end

    // ---------------- datapath regs
    reg [31:0] pc;
    reg [31:0] rs1_val, rs2_val;
    reg [31:0] res;            // result to write back
    reg        res_wb;         // write res to rd in ST_WB
    reg [31:0] shreg;          // serial shift register
    reg  [5:0] shcnt;
    reg        sh_arith, sh_right;
    reg [31:0] trap_pc;
    reg        trap_is_int;
    reg  [3:0] trap_code;
    reg  [1:0] ls_off;         // saved load/store address low bits
    reg        br_taken;

    // decode fields
    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];
    wire [4:0] rd     = instr[11:7];
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // shared adder: A +/- B
    reg  [31:0] add_a, add_b;
    reg         add_sub;
    wire [32:0] add_r   = {1'b0, add_a} + {1'b0, add_sub ? ~add_b : add_b} + {32'b0, add_sub};
    wire        add_cout= add_r[32];
    wire [31:0] add_sum = add_r[31:0];

    wire [4:0] shamt = opcode[5] ? rs2_val[4:0] : imm_i[4:0];
    wire a_s = add_a[31], b_s = add_b[31];
    wire cmp_eq  = (add_sum == 0);
    wire cmp_lt  = (a_s == b_s) ? add_sum[31] : a_s;   // signed a<b
    wire cmp_ltu = !add_cout;                          // unsigned a<b

    // CSR write combinational values
    wire [31:0] csr_src  = funct3[2] ? {27'b0, instr[19:15]} : rs1_val;
    wire [31:0] csr_nval = (funct3[1:0] == 2'b01) ? csr_src :
                          (funct3[1:0] == 2'b10) ? (csr_rdata | csr_src) :
                                                  (csr_rdata & ~csr_src);
    // load extraction
    wire [7:0]  ld_byte = mem_rdata[ls_off * 8 +: 8];
    wire [15:0] ld_half = mem_rdata[{ls_off[1], 4'b0} +: 16];

    wire _unused = &{1'b0, funct7[6], funct7[4:0], instr[4:0], 1'b0};

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= ST_IRQ;
            pc        <= 32'b0;
            mem_valid <= 1'b0;
            mem_wstrb <= 4'b0;
            csr_mie   <= 1'b0;
            csr_mpie  <= 1'b0;
            csr_mtie  <= 1'b0;
            csr_meie  <= 1'b0;
            csr_mtvec <= 32'b0;
            rf_raddr  <= 5'b0;
            res_wb    <= 1'b0;
            shcnt     <= 6'b0;
            shreg     <= 32'b0;
        end else begin
            case (state)
            // ---------- instruction boundary: interrupts first
            ST_IRQ: begin
                if (csr_mie && ((csr_mtie && irq_timer) || (csr_meie && irq_ext))) begin
                    trap_pc     <= pc;
                    trap_is_int <= 1'b1;
                    trap_code   <= (csr_meie && irq_ext) ? 4'hB : 4'h7;
                    state       <= ST_TRAP;
                end else begin
                    mem_valid <= 1'b1;
                    mem_addr  <= pc;
                    mem_wstrb <= 4'b0;
                    state     <= ST_FETCH;
                end
            end
            ST_FETCH: begin
                if (mem_ready) begin
                    mem_valid <= 1'b0;
                    instr     <= mem_rdata;
                    rf_raddr  <= mem_rdata[19:15]; // rs1
                    state     <= ST_RS1;
                end
            end
            ST_RS1: begin
                rs1_val  <= rf_rdata;
                rf_raddr <= instr[24:20]; // rs2
                state    <= ST_RS2;
            end
            ST_RS2: begin
                rs2_val <= rf_rdata;
                state   <= ST_EXEC;
            end
            // ---------- execute dispatch
            ST_EXEC: begin
                res_wb <= 1'b1;
                case (opcode)
                7'b0110111: begin res <= imm_u; state <= ST_WB; end                       // LUI
                7'b0010111: begin add_a <= pc;      add_b <= imm_u; add_sub <= 1'b0;
                                  state <= ST_ALUWB; end                                  // AUIPC
                7'b1101111: begin add_a <= pc;      add_b <= imm_j; add_sub <= 1'b0;
                                  res <= pc + 4;    state <= ST_JT; end                   // JAL
                7'b1100111: begin add_a <= rs1_val; add_b <= imm_i; add_sub <= 1'b0;
                                  res <= pc + 4;    state <= ST_JT; end                   // JALR
                7'b1100011: begin add_a <= rs1_val; add_b <= rs2_val; add_sub <= 1'b1;
                                  res_wb <= 1'b0; state <= ST_BR; end                     // BRANCH
                7'b0000011: begin add_a <= rs1_val; add_b <= imm_i; add_sub <= 1'b0;
                                  res_wb <= 1'b0; state <= ST_LSADDR; end                 // LOAD
                7'b0100011: begin add_a <= rs1_val; add_b <= imm_s; add_sub <= 1'b0;
                                  res_wb <= 1'b0; state <= ST_LSADDR; end                 // STORE
                7'b0010011,                                                                // OP-IMM
                7'b0110011: begin                                                          // OP
                    case (funct3)
                    3'b000, 3'b010, 3'b011: begin // ADD/SUB, SLT, SLTU
                        add_a   <= rs1_val;
                        add_b   <= opcode[5] ? rs2_val : imm_i;
                        add_sub <= (funct3 == 3'b010 || funct3 == 3'b011) ? 1'b1 :
                                   (opcode[5] && funct7[5]); // SUB
                        state   <= ST_ALUWB;
                    end
                    3'b100: begin res <= rs1_val ^ (opcode[5] ? rs2_val : imm_i); state <= ST_WB; end
                    3'b110: begin res <= rs1_val | (opcode[5] ? rs2_val : imm_i); state <= ST_WB; end
                    3'b111: begin res <= rs1_val & (opcode[5] ? rs2_val : imm_i); state <= ST_WB; end
                    default: begin // shifts: funct3 001 (SLL) / 101 (SRL,SRA)
                        shreg    <= rs1_val;
                        shcnt    <= {1'b0, shamt};
                        sh_right <= funct3[2];
                        sh_arith <= funct7[5] & rs1_val[31];
                        state    <= ST_SHIFT;
                    end
                    endcase
                end
                7'b0001111: begin res_wb <= 1'b0; pc <= pc + 4; state <= ST_IRQ; end      // FENCE/FENCE.I
                7'b1110011: begin                                                          // SYSTEM
                    res_wb <= 1'b0;
                    if (funct3 == 3'b000) begin
                        case (instr[31:20])
                        12'h000: begin trap_pc <= pc; trap_is_int <= 0; trap_code <= 4'd11; state <= ST_TRAP; end // ECALL
                        12'h001: begin trap_pc <= pc; trap_is_int <= 0; trap_code <= 4'd3;  state <= ST_TRAP; end // EBREAK
                        12'h302: state <= ST_MRET;
                        12'h105: begin pc <= pc + 4; state <= ST_IRQ; end                 // WFI = NOP
                        default: begin trap_pc <= pc; trap_is_int <= 0; trap_code <= 4'd2; state <= ST_TRAP; end
                        endcase
                    end else begin
                        state <= ST_CSR;
                    end
                end
                default: begin // illegal instruction
                    res_wb      <= 1'b0;
                    trap_pc     <= pc;
                    trap_is_int <= 1'b0;
                    trap_code   <= 4'd2;
                    state       <= ST_TRAP;
                end
                endcase
            end
            // ---------- adder result ready -> res
            ST_ALUWB: begin
                case (funct3)
                3'b010:   res <= {31'b0, cmp_lt};
                3'b011:   res <= {31'b0, cmp_ltu};
                default:  res <= add_sum;
                endcase
                state <= ST_WB;
            end
            // ---------- jump target: adder holds pc+imm or rs1+imm
            ST_JT: begin
                if (add_sum[1]) begin // target bit1 set -> instr addr misaligned
                    trap_pc     <= pc;
                    trap_is_int <= 1'b0;
                    trap_code   <= 4'd0;
                    res_wb      <= 1'b0;
                    state       <= ST_TRAP;
                end else begin
                    pc    <= (opcode == 7'b1100111) ? {add_sum[31:1], 1'b0} : add_sum;
                    if (rd != 0) xregs[rd] <= res; // res holds pc+4
                    res_wb<= 1'b0;
                    state <= ST_IRQ;
                end
            end
            // ---------- branch: compare on adder (rs1-rs2)
            ST_BR: begin
                case (funct3)
                3'b000:  br_taken <= cmp_eq;
                3'b001:  br_taken <= !cmp_eq;
                3'b100:  br_taken <= cmp_lt;
                3'b101:  br_taken <= !cmp_lt;
                3'b110:  br_taken <= cmp_ltu;
                3'b111:  br_taken <= !cmp_ltu;
                default: br_taken <= 1'b0;
                endcase
                add_a   <= pc;
                add_b   <= imm_b;
                add_sub <= 1'b0;
                res_wb  <= 1'b0;
                state   <= ST_BRT;
            end
            // ---------- branch target / fall-through
            ST_BRT: begin
                if (!br_taken) begin
                    add_a   <= pc;
                    add_b   <= 32'd4;
                    add_sub <= 1'b0;
                    state   <= ST_BRPC;
                end else if (add_sum[1]) begin
                    trap_pc     <= pc;
                    trap_is_int <= 1'b0;
                    trap_code   <= 4'd0;
                    state       <= ST_TRAP;
                end else begin
                    pc    <= add_sum;
                    state <= ST_IRQ;
                end
            end
            ST_BRPC: begin
                pc    <= add_sum;
                state <= ST_IRQ;
            end
            // ---------- serial shift, 1 bit/cycle
            ST_SHIFT: begin
                if (shcnt == 0) begin
                    res   <= shreg;
                    state <= ST_WB;
                end else begin
                    shcnt <= shcnt - 1;
                    if (sh_right) shreg <= {sh_arith & shreg[31], shreg[31:1]};
                    else          shreg <= {shreg[30:0], 1'b0};
                end
            end
            // ---------- load/store EA in adder
            ST_LSADDR: begin
                ls_off <= add_sum[1:0];
                if ((funct3 == 3'b010 && add_sum[1:0] != 0) ||              // LW/SW misalign
                    ((funct3 == 3'b001 || funct3 == 3'b101) && add_sum[0])) begin // LH/LHU/SH
                    trap_pc     <= pc;
                    trap_is_int <= 1'b0;
                    trap_code   <= (opcode == 7'b0100011) ? 4'd6 : 4'd4;
                    res_wb      <= 1'b0;
                    state       <= ST_TRAP;
                end else begin
                    mem_valid <= 1'b1;
                    mem_addr  <= {add_sum[31:2], 2'b00};
                    if (opcode == 7'b0100011) begin
                        case (funct3)
                        3'b000: begin // SB
                            mem_wstrb <= 4'b0001 << add_sum[1:0];
                            mem_wdata <= rs2_val << {add_sum[1:0], 3'b0};
                        end
                        3'b001: begin // SH
                            mem_wstrb <= 4'b0011 << {add_sum[1], 1'b0};
                            mem_wdata <= rs2_val << {add_sum[1], 4'b0};
                        end
                        default: begin mem_wstrb <= 4'b1111; mem_wdata <= rs2_val; end
                        endcase
                    end else begin
                        mem_wstrb <= 4'b0000;
                    end
                    state <= ST_MEM;
                end
            end
            ST_MEM: begin
                if (mem_ready) begin
                    mem_valid <= 1'b0;
                    res_wb    <= 1'b0;
                    if (opcode == 7'b0000011) state <= ST_LDEXT;
                    else begin
                        pc    <= pc + 4;   // store complete
                        state <= ST_IRQ;
                    end
                end
            end
            ST_LDEXT: begin
                case (funct3)
                3'b000:  res <= {{24{ld_byte[7]}},  ld_byte};   // LB
                3'b001:  res <= {{16{ld_half[15]}}, ld_half};   // LH
                3'b010:  res <= mem_rdata;                      // LW
                3'b100:  res <= {24'b0, ld_byte};               // LBU
                default: res <= {16'b0, ld_half};               // LHU
                endcase
                res_wb <= 1'b1;
                state  <= ST_WB;
            end
            // ---------- CSR
            ST_CSR: begin
                res     <= csr_rdata; // old value -> rd
                res_wb  <= 1'b1;
                if (csr_hit && (funct3[1:0] == 2'b01 || instr[19:15] != 5'b0)) begin
                    case (instr[31:20])
                    12'h300: begin csr_mie <= csr_nval[3]; csr_mpie <= csr_nval[7]; end
                    12'h304: begin csr_mtie <= csr_nval[7]; csr_meie <= csr_nval[11]; end
                    12'h305: csr_mtvec    <= csr_nval;
                    12'h340: csr_mscratch <= csr_nval;
                    12'h341: csr_mepc     <= csr_nval;
                    default: ; // RO / unimplemented: ignore
                    endcase
                end
                state <= ST_WB;
            end
            ST_MRET: begin
                pc       <= csr_mepc;
                csr_mie  <= csr_mpie;
                csr_mpie <= 1'b1;
                res_wb   <= 1'b0;
                state    <= ST_IRQ;
            end
            ST_TRAP: begin
                csr_mepc        <= trap_pc;
                csr_mcause_int  <= trap_is_int;
                csr_mcause_code <= trap_code;
                csr_mpie        <= csr_mie;
                csr_mie         <= 1'b0;
                pc              <= {csr_mtvec[31:2], 2'b00};
                res_wb          <= 1'b0;
                state           <= ST_IRQ;
            end
            ST_WB: begin
                if (res_wb && rd != 0) xregs[rd] <= res;
                res_wb <= 1'b0;
                pc     <= pc + 4;   // sequential next instruction
                state  <= ST_IRQ;
            end
            default: state <= ST_IRQ;
            endcase
        end
    end

endmodule
