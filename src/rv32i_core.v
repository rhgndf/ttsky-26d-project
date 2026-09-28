`default_nettype none
// RV32I core — 1x1-tile nibble-serial implementation.
// Register file lives in PSRAM: x[i] at byte address 0xFFFF80 + 4*i (x0 never touched).
// 24-bit PC (byte address, [1:0]=0), mtvec fixed = 4, machine CSRs per docs/architecture.md.
//
// Bus interface (picorv32-style): mem_valid held until a 1-clk mem_ready pulse.
// Reads leave the word on mem_rdata (stable); writes are always full words
// (sub-word stores merge into mem_wdata in the core after a read).
//
// Datapath: A[31:0] accumulator/shift register, B[23:0] effective address (+periph flag),
// IR[31:0], carry c, sign sgn/bsign, nibble counter ncnt, bit counter bcnt.
// All arithmetic is 4 bits wide through alu_res; operands come from a nibble mux.
// Microsequencer: leaf subroutines (RREG/WREG/PASS/ROTR/ROTL/SHF/MEMR/MEMW)
// return through `ret`; macro states chain them per instruction.

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

    // ---------------- architectural state
    reg [23:0] pc;
    reg [31:0] ir;
    reg [31:0] a;
    reg [23:0] b;
    reg        b_periph;
    // CSRs
    reg        csr_mie, csr_mpie;
    reg        csr_mtie, csr_meie;
    reg [23:0] csr_mepc;
    reg        csr_mcause_int;
    reg [3:0]  csr_mcause_code;
    // datapath
    reg        c, sgn;
    reg        eq_acc, lt_f, ltu_f;
    reg        keepa;       // S_RREG_W: leave A untouched when set
    reg  [1:0] loff;
    reg  [2:0] ncnt;
    reg  [4:0] bcnt;
    reg  [4:0] shamt;
    reg  [4:0] rd_idx;
    reg  [5:0] state, ret;

    // ---------------- decode
    wire [6:0] opcode = ir[6:0];
    wire [4:0] rd     = ir[11:7];
    wire [2:0] funct3 = ir[14:12];
    wire [4:0] rs1    = ir[19:15];
    wire [4:0] rs2    = ir[24:20];

    // ---------------- immediates
    wire [31:0] imm_i = {{20{ir[31]}}, ir[31:20]};
    wire [31:0] imm_s = {{20{ir[31]}}, ir[31:25], ir[11:7]};
    wire [31:0] imm_b = {{19{ir[31]}}, ir[31], ir[7], ir[30:25], ir[11:8], 1'b0};
    wire [31:0] imm_u = {ir[31:12], 12'b0};
    wire [31:0] imm_j = {{11{ir[31]}}, ir[31], ir[19:12], ir[20], ir[30:21], 1'b0};
    reg  [31:0] imm32;
    always @(*) begin
        case (opcode)
        7'b0110111, 7'b0010111: imm32 = imm_u;
        7'b1101111:             imm32 = imm_j;
        7'b1100011:             imm32 = imm_b;
        7'b0100011:             imm32 = imm_s;
        default:                imm32 = imm_i;
        endcase
    end

    // ---------------- CSR read value
    reg [31:0] csr_val;
    reg        csr_hit;
    always @(*) begin
        csr_hit  = 1'b1;
        case (ir[31:20])
        12'h300: csr_val = {19'b0, 2'b11, 3'b0, csr_mpie, 3'b0, csr_mie, 3'b0}; // mstatus
        12'h304: csr_val = {20'b0, csr_meie, 3'b0, csr_mtie, 7'b0};              // mie
        12'h305: csr_val = 32'd4;                                              // mtvec RO
        12'h341: csr_val = {8'b0, csr_mepc};                                   // mepc
        12'h342: csr_val = {csr_mcause_int, 27'b0, csr_mcause_code};           // mcause
        12'h344: csr_val = {20'b0, irq_ext, 3'b0, irq_timer, 7'b0};            // mip RO
        default: begin csr_val = 32'b0; csr_hit = 1'b0; end                    // read 0
        endcase
    end

    // ---------------- operand nibble mux
    localparam OP_RDATA = 3'd0,
               OP_IMM   = 3'd1,
               OP_CSR   = 3'd2,
               OP_PC    = 3'd3,
               OP_CONST = 3'd4,   // 4 on nibble 0 else 0
               OP_ZERO  = 3'd5;
    reg  [2:0]  op_sel;
    wire [31:0] pc_ext = {8'b0, pc};
    wire [3:0]  op_nib = (op_sel == OP_RDATA) ? mem_rdata[ncnt*4 +: 4] :
                       (op_sel == OP_IMM)   ? imm32[ncnt*4 +: 4]    :
                       (op_sel == OP_CSR)   ? csr_val[ncnt*4 +: 4]  :
                       (op_sel == OP_PC)    ? pc_ext[ncnt*4 +: 4]   :
                       (op_sel == OP_CONST) ? (ncnt == 3'd0 ? 4'd4 : 4'd0) :
                                              4'b0;

    // ---------------- 4-bit ALU
    localparam ALU_ADD = 3'd0, ALU_SUB = 3'd1, ALU_AND = 3'd2, ALU_OR = 3'd3,
               ALU_XOR = 3'd4, ALU_PASS = 3'd5, ALU_ANDN = 3'd6;
    reg [2:0] alu_op;
    reg [4:0] alu_res;
    always @(*) begin
        case (alu_op)
        ALU_SUB:   alu_res = {1'b0, a[3:0]} + {1'b0, ~op_nib} + {4'b0, c};
        ALU_AND:   alu_res = {1'b0, a[3:0] & op_nib};
        ALU_OR:    alu_res = {1'b0, a[3:0] | op_nib};
        ALU_XOR:   alu_res = {1'b0, a[3:0] ^ op_nib};
        ALU_PASS:  alu_res = {1'b0, op_nib};
        ALU_ANDN:  alu_res = {1'b0, ~a[3:0] & op_nib};  // CSRC: old & ~src (a=src)
        default:   alu_res = {1'b0, a[3:0]} + {1'b0, op_nib} + {4'b0, c};
        endcase
    end

    // regfile word address: 0xFFFF80 + 4*idx
    wire [23:0] rf_addr = {16'hFFFF, 1'b1, rd_idx, 2'b00};
    // effective bus address from b
    wire [31:0] bus_addr = b_periph ? (32'h2000_0000 | {20'b0, b[11:0]})
                                    : {8'b0, b[23:2], 2'b00};

    // store byte strobes for sub-word PSRAM RMW
    reg  [3:0]  st_strb;
    wire [31:0] merge_wdata =
        { (st_strb[3] ? a[31:24] : mem_rdata[31:24]),
          (st_strb[2] ? a[23:16] : mem_rdata[23:16]),
          (st_strb[1] ? a[15:8]  : mem_rdata[15:8]),
          (st_strb[0] ? a[7:0]   : mem_rdata[7:0]) };

    wire irq_pend = csr_mie && ((csr_mtie && irq_timer) || (csr_meie && irq_ext));

    // load-extension keep count: LB/LBU keep 2 nibbles, LH/LHU keep 4, LW all
    wire [2:0] ext_keepn = funct3[2] ? (funct3[0] ? 3'd4 : 3'd2)
                                   : (funct3 == 3'b010 ? 3'd0 : (funct3[0] ? 3'd4 : 3'd2));

    // ---------------- states
    localparam S_IRQ = 0, S_FETCH = 1, S_DEC = 2,
        // macro states
        M_WRD     = 3,   // write a -> rf[rd_idx], then pc+4
        M_JAL_L   = 4,   // JAL: write link, then compute target
        M_JAL_T   = 5,   // JAL: a = pc + imm_j -> pc
        M_JALR_B  = 6,   // latch jalr target; start link pass
        M_JALR_L  = 7,   // write link rd if needed
        M_JALR_PC = 8,   // pc <= b
        M_BR_CMP  = 9,   // decide branch from flags after compare pass
        M_EA      = 10,  // capture b/loff/periph from a; dispatch load/store
        M_LD1     = 11,  // a <= rdata; start rotate-right
        M_LD2     = 12,  // save sign; start extension pass
        M_LDEXT   = 13,  // extension done -> write rd
        M_ST2     = 14,  // a = rs2 data; start rotate-left
        M_ST3     = 15,  // choose direct write or RMW
        M_ST4     = 16,  // issue merged write after RMW read
        M_OP1     = 17,  // a = rs1 loaded; dispatch per opcode
        M_OP2     = 18,  // rs2 word on rdata (or zero); run ALU pass or shift
        M_OPRES   = 19,  // slt/sltu fixup then write rd
        M_SH0     = 20,  // init bit-shift loop
        M_CSR1    = 21,  // a = old csr; write rd if nonzero
        M_CSR2    = 22,  // load src operand into a
        M_CSR3    = 23,  // compute nval (pass for RS/RC)
        M_CSR4    = 24,  // csr flops <= a; pc+4
        M_MRET    = 25,  // pc <= mepc; restore mie
        S_PC4     = 26,  // pc <= pc+4 -> IRQ
        M_PCSET   = 27,  // pc <= a[23:0]&~3 -> IRQ (jump/branch target)
        // leaf subroutines (return via ret)
        S_RREG    = 32,  // read rf[rd_idx] -> rdata (+a unless keepa)
        S_RREG_W  = 33,
        S_WREG    = 34,  // write a -> rf[rd_idx]
        S_WREG_W  = 35,
        S_PASS    = 36,  // 8 nibble ALU steps
        S_ROTR    = 37,  // a <= rotr4(a), bcnt times
        S_ROTL    = 38,  // a <= rotl4(a), bcnt times
        S_SHF     = 39,  // 1-bit shift, bcnt times
        S_MEMR    = 40,  // issue read at b
        S_MEMR_W  = 41,
        S_MEMW    = 42,  // issue write at b (wdata preset by caller)
        S_MEMW_W  = 43,
        S_EXT     = 44;  // load sign/zero extension pass

    task do_trap(input [3:0] code);
        begin
            csr_mepc        <= pc;
            csr_mpie        <= csr_mie;
            csr_mie         <= 1'b0;
            csr_mcause_int  <= 1'b0;
            csr_mcause_code <= code;
            pc              <= 24'd4;
            state           <= S_IRQ;
        end
    endtask

    // start a compare/branch taken pass: a = pc + imm_b -> M_PCSET
    task br_target;
        begin
            a <= pc_ext; op_sel <= OP_IMM; alu_op <= ALU_ADD; c <= 1'b0;
            ret <= M_PCSET; state <= S_PASS;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_n) begin
            pc <= 0; ir <= 0; a <= 0; b <= 0; b_periph <= 0;
            csr_mie <= 0; csr_mpie <= 0; csr_mtie <= 0; csr_meie <= 0;
            csr_mepc <= 0; csr_mcause_int <= 0; csr_mcause_code <= 0;
            c <= 0; sgn <= 0; eq_acc <= 1; lt_f <= 0; ltu_f <= 0;
            keepa <= 0; loff <= 0; ncnt <= 0; bcnt <= 0; shamt <= 0; rd_idx <= 0;
            st_strb <= 0;
            mem_valid <= 0; mem_addr <= 0; mem_wdata <= 0; mem_wstrb <= 0;
            op_sel <= OP_ZERO; alu_op <= ALU_ADD;
            state <= S_IRQ; ret <= S_IRQ;
        end else begin
            case (state)
            // ================= top-level =================
            S_IRQ: begin
                if (irq_pend) begin
                    csr_mepc        <= pc;
                    csr_mpie        <= csr_mie;
                    csr_mie         <= 1'b0;
                    csr_mcause_int  <= 1'b1;
                    csr_mcause_code <= (csr_meie && irq_ext) ? 4'd11 : 4'd7;
                    pc              <= 24'd4;
                end
                mem_addr  <= {8'b0, irq_pend ? 24'd4 : pc};
                mem_wstrb <= 4'b0;
                mem_valid <= 1'b1;
                state     <= S_FETCH;
            end
            S_FETCH: if (mem_ready) begin
                mem_valid <= 1'b0;
                ir        <= mem_rdata;
                state     <= S_DEC;
            end
            S_DEC: begin
                ncnt   <= 3'b0;
                eq_acc <= 1'b1;
                case (opcode)
                7'b0110111: begin // LUI: a = imm_u
                    op_sel <= OP_IMM; alu_op <= ALU_PASS; rd_idx <= rd;
                    ret <= M_WRD; state <= S_PASS;
                end
                7'b0010111: begin // AUIPC: a = pc + imm_u
                    a <= pc_ext; op_sel <= OP_IMM; alu_op <= ALU_ADD; c <= 1'b0;
                    rd_idx <= rd; ret <= M_WRD; state <= S_PASS;
                end
                7'b1101111: begin // JAL: link = pc+4, then pc += imm_j
                    a <= pc_ext; op_sel <= OP_CONST; alu_op <= ALU_ADD; c <= 1'b0;
                    rd_idx <= rd; ret <= M_JAL_L; state <= S_PASS;
                end
                7'b1100111, 7'b1100011, 7'b0000011, 7'b0100011,
                7'b0010011, 7'b0110011: begin // rs1 -> a via regfile read
                    if (rs1 != 0) begin
                        keepa <= 1'b0;
                        rd_idx <= rs1; ret <= M_OP1; state <= S_RREG;
                    end else begin
                        a <= 32'b0; state <= M_OP1;
                    end
                end
                7'b0001111: begin pc <= pc + 4; state <= S_IRQ; end // FENCE
                7'b1110011: begin // SYSTEM
                    if (funct3 == 3'b000) begin
                        case (ir[31:20])
                        12'h000: do_trap(4'd11);
                        12'h001: do_trap(4'd3);
                        12'h302: state <= M_MRET;
                        12'h105: begin pc <= pc + 4; state <= S_IRQ; end // WFI
                        default: do_trap(4'd2);
                        endcase
                    end else begin // CSR
                        op_sel <= OP_CSR; alu_op <= ALU_PASS;
                        ret <= M_CSR1; state <= S_PASS;
                    end
                end
                default: do_trap(4'd2);
                endcase
            end

            // ---- JAL / JALR ----
            M_JAL_L: begin // a = pc+4 (link); write rd then compute target
                if (rd_idx != 0) begin ret <= M_JAL_T; state <= S_WREG; end
                else             state <= M_JAL_T;
            end
            M_JAL_T: begin // a = pc + imm_j -> pc
                a <= pc_ext; op_sel <= OP_IMM; alu_op <= ALU_ADD; c <= 1'b0;
                ret <= M_PCSET; state <= S_PASS;
            end
            M_PCSET: begin
                pc    <= {a[23:2], 2'b00};
                state <= S_IRQ;
            end
            M_JALR_B: begin // a = rs1+imm_i (target); latch, then link pass
                b  <= {a[23:1], 1'b0};
                a  <= pc_ext; op_sel <= OP_CONST; alu_op <= ALU_ADD; c <= 1'b0;
                rd_idx <= rd; ret <= M_JALR_L; state <= S_PASS;
            end
            M_JALR_L: begin // a = pc+4; write rd if needed
                if (rd_idx != 0) begin ret <= M_JALR_PC; state <= S_WREG; end
                else             state <= M_JALR_PC;
            end
            M_JALR_PC: begin
                pc    <= {b[23:2], 2'b00}; // mask to word (misaligned trap dropped)
                state <= S_IRQ;
            end
            M_MRET: begin
                pc       <= csr_mepc;
                csr_mie  <= csr_mpie;
                csr_mpie <= 1'b1;
                state    <= S_IRQ;
            end
            // ---- branch ----
            M_BR_CMP: begin
                case (funct3)
                3'b000: if (eq_acc)  br_target; else begin pc <= pc + 4; state <= S_IRQ; end
                3'b001: if (!eq_acc) br_target; else begin pc <= pc + 4; state <= S_IRQ; end
                3'b100: if (lt_f)    br_target; else begin pc <= pc + 4; state <= S_IRQ; end
                3'b101: if (!lt_f)   br_target; else begin pc <= pc + 4; state <= S_IRQ; end
                3'b110: if (ltu_f)   br_target; else begin pc <= pc + 4; state <= S_IRQ; end
                default: if (!ltu_f) br_target; else begin pc <= pc + 4; state <= S_IRQ; end
                endcase
            end
            // ---- EA capture ----
            M_EA: begin
                b        <= a[23:0];
                b_periph <= (a[29:28] == 2'b10);
                loff     <= a[1:0];
                if (opcode == 7'b0000011) begin
                    ret <= M_LD1; state <= S_MEMR;
                end else begin
                    st_strb <= (funct3 == 3'b000) ? (4'b0001 << a[1:0]) :
                               (funct3 == 3'b001) ? (4'b0011 << {a[1], 1'b0}) :
                                                   4'b1111;
                    if (rs2 != 0) begin
                        keepa <= 1'b0;   // a <= rs2 (store data)
                        rd_idx <= rs2; ret <= M_ST2; state <= S_RREG;
                    end else begin
                        a <= 32'b0; state <= M_ST2;
                    end
                end
            end
            // ---- load ----
            M_LD1: begin
                a    <= mem_rdata;
                bcnt <= {2'b0, loff, 1'b0};
                if (loff != 0) begin ret <= M_LD2; state <= S_ROTR; end
                else           state <= M_LD2;
            end
            M_LD2: begin
                sgn  <= (funct3 == 3'b000) ? a[7] : a[15];
                ncnt <= 3'b0;
                state <= S_EXT;
            end
            M_LDEXT: begin
                rd_idx <= rd; state <= M_WRD;
            end
            // ---- store ----
            M_ST2: begin // a = rs2 word; rotate left by off*2 nibbles
                bcnt <= {2'b0, loff, 1'b0};
                if (loff != 0) begin ret <= M_ST3; state <= S_ROTL; end
                else           state <= M_ST3;
            end
            M_ST3: begin
                mem_wdata <= a;
                if (b_periph || st_strb == 4'b1111) begin
                    ret <= S_PC4; state <= S_MEMW;
                end else begin
                    ret <= M_ST4; state <= S_MEMR;   // RMW: read old word first
                end
            end
            M_ST4: begin // rdata = old word; write merged
                mem_wdata <= merge_wdata;
                ret <= S_PC4; state <= S_MEMW;
            end
            // ---- OP / OP-IMM dispatch (a = rs1) ----
            M_OP1: begin
                ncnt   <= 3'b0;
                eq_acc <= 1'b1;
                sgn    <= a[31];
                case (opcode)
                7'b1100111: begin // JALR: a = rs1 + imm_i -> b
                    op_sel <= OP_IMM; alu_op <= ALU_ADD; c <= 1'b0;
                    ret <= M_JALR_B; state <= S_PASS;
                end
                7'b1100011: begin // branch: read rs2 (keep a), subtract pass
                    if (rs2 != 0) begin
                        keepa <= 1'b1;
                        rd_idx <= rs2; ret <= M_OP2; state <= S_RREG;
                    end else begin
                        op_sel <= OP_ZERO; alu_op <= ALU_SUB; c <= 1'b1;
                        ret <= M_BR_CMP; state <= S_PASS;
                    end
                end
                7'b0000011, 7'b0100011: begin // EA pass: a = rs1 + imm
                    op_sel <= OP_IMM; alu_op <= ALU_ADD; c <= 1'b0;
                    ret <= M_EA; state <= S_PASS;
                end
                7'b0010011: begin // OP-IMM
                    rd_idx <= rd;
                    if (funct3 == 3'b001 || funct3 == 3'b101) begin // shifts
                        shamt <= ir[24:20];
                        state <= M_SH0;
                    end else begin
                        op_sel <= OP_IMM;
                        case (funct3)
                        3'b000: begin alu_op <= ALU_ADD; c <= 1'b0; end
                        3'b010, 3'b011: begin alu_op <= ALU_SUB; c <= 1'b1; end
                        3'b100: alu_op <= ALU_XOR;
                        3'b110: alu_op <= ALU_OR;
                        default: alu_op <= ALU_AND;
                        endcase
                        ret <= M_OPRES; state <= S_PASS;
                    end
                end
                default: begin // OP (R-type): fetch rs2, keep a
                    if (rs2 != 0) begin
                        keepa <= 1'b1;
                        rd_idx <= rs2; ret <= M_OP2; state <= S_RREG;
                    end else begin
                        state <= M_OP2;
                    end
                end
                endcase
            end
            M_OP2: begin
                rd_idx <= rd;
                eq_acc <= 1'b1;
                if (opcode == 7'b0110011 &&
                    (funct3 == 3'b001 || funct3 == 3'b101)) begin // SLL/SRL/SRA
                    shamt <= (rs2 != 0) ? mem_rdata[4:0] : 5'b0;
                    state <= M_SH0;
                end else if (opcode == 7'b1100011) begin
                    op_sel <= (rs2 != 0) ? OP_RDATA : OP_ZERO;
                    alu_op <= ALU_SUB; c <= 1'b1;
                    ret <= M_BR_CMP; state <= S_PASS;
                end else begin
                    op_sel <= (rs2 != 0) ? OP_RDATA : OP_ZERO;
                    case (funct3)
                    3'b000: begin alu_op <= ir[30] ? ALU_SUB : ALU_ADD;
                                  c <= ir[30]; end
                    3'b010, 3'b011: begin alu_op <= ALU_SUB; c <= 1'b1; end
                    3'b100: alu_op <= ALU_XOR;
                    3'b110: alu_op <= ALU_OR;
                    default: alu_op <= ALU_AND;
                    endcase
                    ret <= M_OPRES; state <= S_PASS;
                end
            end
            M_OPRES: begin // SLT/SLTU fixup: a = {31'b0, lt}
                if ((opcode == 7'b0010011 || opcode == 7'b0110011) &&
                    (funct3 == 3'b010 || funct3 == 3'b011))
                    a <= {31'b0, (funct3 == 3'b010) ? lt_f : ltu_f};
                state <= M_WRD;
            end
            M_WRD: begin // write rd (rd_idx==rd) unless x0, then pc+4
                if (rd_idx != 0) begin ret <= S_PC4; state <= S_WREG; end
                else             begin pc <= pc + 4; state <= S_IRQ; end
            end
            S_PC4: begin pc <= pc + 4; state <= S_IRQ; end
            // ---- shift loop init ----
            M_SH0: begin
                bcnt <= shamt;
                if (shamt == 0) begin
                    state <= M_WRD; // rd_idx already set
                end else begin
                    sgn <= a[31] & ir[30] & funct3[2]; // SRA fill (funct3=101, ir30)
                    ret <= M_WRD; state <= S_SHF;
                end
            end
            // ---- CSR ----
            M_CSR1: begin // a = old csr; write rd then load src
                rd_idx <= rd;
                if (rd != 0) begin ret <= M_CSR2; state <= S_WREG; end
                else         state <= M_CSR2;
            end
            M_CSR2: begin // a <= src = zimm or rs1
                ncnt <= 3'b0;
                if (funct3[2]) begin
                    a <= {27'b0, rs1};
                    state <= M_CSR3;
                end else if (rs1 != 0) begin
                    keepa <= 1'b0;   // a <= rs1 (old csr already written to rd)
                    rd_idx <= rs1; ret <= M_CSR3; state <= S_RREG;
                end else begin
                    a <= 32'b0;
                    state <= M_CSR3;
                end
            end
            M_CSR3: begin
                if (funct3[1:0] == 2'b01) state <= M_CSR4;          // CSRRW: nval=a
                else if (rs1 == 0)        state <= S_PC4;           // RS/RC rs1=0: read-only
                else begin
                    op_sel <= OP_CSR;
                    alu_op <= (funct3[1:0] == 2'b10) ? ALU_OR : ALU_ANDN;
                    c  <= 1'b0;
                    ret <= M_CSR4; state <= S_PASS;
                end
            end
            M_CSR4: begin // csr flops <= a
                if (csr_hit) begin
                    case (ir[31:20])
                    12'h300: begin csr_mie <= a[3]; csr_mpie <= a[7]; end
                    12'h304: begin csr_mtie <= a[7]; csr_meie <= a[11]; end
                    12'h341: csr_mepc <= {a[23:2], 2'b00};
                    12'h342: begin csr_mcause_int <= a[31]; csr_mcause_code <= a[3:0]; end
                    default: ;
                    endcase
                end
                pc    <= pc + 4;
                state <= S_IRQ;
            end

            // ================= leaf subroutines =================
            S_RREG: begin
                mem_addr  <= {8'b0, rf_addr};
                mem_wstrb <= 4'b0;
                mem_valid <= 1'b1;
                state     <= S_RREG_W;
            end
            S_RREG_W: if (mem_ready) begin
                mem_valid <= 1'b0;
                if (!keepa) a <= mem_rdata;
                state <= ret;
            end
            S_WREG: begin
                mem_addr  <= {8'b0, rf_addr};
                mem_wdata <= a;
                mem_wstrb <= 4'b1111;
                mem_valid <= 1'b1;
                state     <= S_WREG_W;
            end
            S_WREG_W: if (mem_ready) begin
                mem_valid <= 1'b0;
                state     <= ret;
            end
            S_PASS: begin // a <= {alu(a[3:0], opnd, c), a[31:4]} x8
                a      <= {alu_res[3:0], a[31:4]};
                c      <= alu_res[4];
                eq_acc <= eq_acc && (alu_res[3:0] == 4'b0);
                if (ncnt == 3'd7) begin
                    lt_f  <= alu_res[3] ^ ((sgn ^ op_nib[3]) & (sgn ^ alu_res[3]));
                    ltu_f <= ~alu_res[4];
                    ncnt  <= 3'b0;      // auto-reset for the next pass
                    state <= ret;
                end else ncnt <= ncnt + 3'd1;
            end
            S_EXT: begin // extension pass (lw: keepn=0 keeps all nibbles)
                a <= { (ext_keepn == 0 || ncnt < ext_keepn) ? a[3:0]
                       : (funct3[2] ? 4'b0 : {4{sgn}}), a[31:4] };
                if (ncnt == 3'd7) begin ncnt <= 3'b0; state <= M_LDEXT; end
                else ncnt <= ncnt + 3'd1;
            end
            S_ROTR: begin a <= {a[3:0], a[31:4]};   if (bcnt == 1) state <= ret; else bcnt <= bcnt - 1; end
            S_ROTL: begin a <= {a[27:0], a[31:28]}; if (bcnt == 1) state <= ret; else bcnt <= bcnt - 1; end
            S_SHF: begin
                if (funct3 == 3'b001) a <= {a[30:0], 1'b0};   // SLL
                else                  a <= {sgn, a[31:1]};    // SRL/SRA
                if (bcnt == 5'd1) begin
                    state <= M_WRD;
                end else bcnt <= bcnt - 5'd1;
            end
            S_MEMR: begin // issue read at b
                mem_addr  <= bus_addr;
                mem_wstrb <= 4'b0;
                mem_valid <= 1'b1;
                state     <= S_MEMR_W;
            end
            S_MEMR_W: if (mem_ready) begin
                mem_valid <= 1'b0;
                state     <= ret;
            end
            S_MEMW: begin // issue write at b (mem_wdata preset by caller)
                mem_addr  <= bus_addr;
                mem_wstrb <= 4'b1111;
                mem_valid <= 1'b1;
                state     <= S_MEMW_W;
            end
            S_MEMW_W: if (mem_ready) begin
                mem_valid <= 1'b0;
                state     <= ret;
            end
            default: state <= S_IRQ;
            endcase
        end
    end

endmodule
