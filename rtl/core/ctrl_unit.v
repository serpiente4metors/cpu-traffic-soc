// ctrl_unit.v —— RV32IM/Zicsr 译码（ID 级纯组合）
// 控制字在 ID→E1 锁存，E1 级内没有译码逻辑。

module ctrl_unit (
    input  wire [31:0] instr,
    input  wire [31:0] imm_i,
    input  wire [31:0] imm_s,
    input  wire [31:0] imm_b,
    input  wire [31:0] imm_u,
    input  wire [31:0] imm_j,

    output reg  [ 3:0] alu_op,
    output reg  [31:0] imm,       // 选中的立即数
    output reg         a_pc,      // ALU a 取 pc（auipc）
    output reg         b_imm,     // ALU b 取 imm
    output reg         reg_we,
    output reg         is_load,
    output reg         is_store,
    output reg  [ 1:0] size,      // 00=B 01=H 10=W
    output reg         uns,       // 无符号 load
    output reg  [ 2:0] br,        // 000=none 001=BEQ 010=BNE 011=BLT 100=BGE 101=BLTU 110=BGEU
    output reg  [ 1:0] jump,      // 0=none 1=JAL 2=JALR
    output reg         is_mul,    // RV32M：mul/mulh/mulhsu/mulhu
    output reg         is_div,    // RV32M：div/divu/rem/remu
    output reg  [ 2:0] funct3,    // 原始 funct3（乘除法用它选具体操作）
    output reg         is_csr,    // csrrw/s/c 及其立即数形式
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_mret,
    output reg         illegal
);

    localparam [3:0] ALU_ADD=4'd0, ALU_SUB=4'd1, ALU_SLL=4'd2, ALU_SLT=4'd3,
                     ALU_SLTU=4'd4, ALU_XOR=4'd5, ALU_SRL=4'd6, ALU_SRA=4'd7,
                     ALU_OR=4'd8,  ALU_AND=4'd9, ALU_PASS_B=4'd10;

    localparam [6:0] OP_LUI=7'b0110111, OP_AUIPC=7'b0010111, OP_JAL=7'b1101111,
                     OP_JALR=7'b1100111, OP_BR=7'b1100011, OP_LOAD=7'b0000011,
                     OP_STORE=7'b0100011, OP_IMM=7'b0010011, OP_REG=7'b0110011,
                     OP_SYS=7'b1110011;

    wire [6:0] op    = instr[6:0];
    wire [6:0] f7    = instr[31:25];
    wire [2:0] f3    = instr[14:12];
    wire [2:0] f3b   = instr[14:12];
    wire       f7b5  = instr[30];        // funct7[5]
    wire [2:0] bf3   = instr[14:12];

// ---------------- ALU 操作（OP / OP-IMM 共用 funct3 映射） ----------------
    reg [3:0] alu_r;
    always @* begin
        case (f3b)
            3'b000: alu_r = (f7b5 && (op == OP_REG)) ? ALU_SUB : ALU_ADD;
            3'b001: alu_r = ALU_SLL;
            3'b010: alu_r = ALU_SLT;
            3'b011: alu_r = ALU_SLTU;
            3'b100: alu_r = ALU_XOR;
            3'b101: alu_r = f7b5 ? ALU_SRA : ALU_SRL;
            3'b110: alu_r = ALU_OR;
            3'b111: alu_r = ALU_AND;
            default: alu_r = ALU_ADD;
        endcase
    end

    always @* begin
// 默认值：一条"什么也不做"的指令
        alu_op   = ALU_ADD;
        imm      = imm_i;
        a_pc     = 1'b0;
        b_imm    = 1'b0;
        reg_we   = 1'b0;
        is_load  = 1'b0;
        is_store = 1'b0;
        size     = 2'b10;
        uns      = 1'b0;
        br       = 3'b000;
        jump     = 2'b00;
        is_mul   = 1'b0;
        is_div   = 1'b0;
        funct3   = f3b;
        is_csr   = 1'b0;
        is_ecall = 1'b0;
        is_ebreak= 1'b0;
        is_mret  = 1'b0;
        illegal  = 1'b0;

        case (op)
// ---------------- 寄存器-寄存器 ----------------
            OP_REG: begin
                if (f7 == 7'b0000001) begin
// ---- RV32M ----
//   funct3 000..011 = mul 族，100..111 = div 族
                    if (f3b[2]) is_div = 1'b1;
                    else        is_mul = 1'b1;
                    reg_we = 1'b1;
                end else if (f7 == 7'b0000000 || f7 == 7'b0100000) begin
                    alu_op = alu_r;
                    reg_we = 1'b1;
                end else begin
                    illegal = 1'b1;        // funct7 非法
                end
            end
// ---------------- 立即数算术 ----------------
            OP_IMM: begin
                alu_op  = alu_r;
                imm     = imm_i;
                b_imm   = 1'b1;
                reg_we  = 1'b1;
            end
// ---------------- LUI / AUIPC ----------------
            OP_LUI: begin
                alu_op  = ALU_PASS_B;
                imm     = imm_u;
                b_imm   = 1'b1;
                reg_we  = 1'b1;
            end
            OP_AUIPC: begin
                alu_op  = ALU_ADD;
                imm     = imm_u;
                a_pc    = 1'b1;
                b_imm   = 1'b1;
                reg_we  = 1'b1;
            end
// ---------------- 取数 ----------------
            OP_LOAD: begin
                alu_op  = ALU_ADD;
                imm     = imm_i;
                b_imm   = 1'b1;
                reg_we  = 1'b1;
                is_load = 1'b1;
                case (f3)
                    3'b000: begin size = 2'b00; uns = 1'b0; end // lb
                    3'b001: begin size = 2'b01; uns = 1'b0; end // lh
                    3'b010: begin size = 2'b10; uns = 1'b0; end // lw
                    3'b100: begin size = 2'b00; uns = 1'b1; end // lbu
                    3'b101: begin size = 2'b01; uns = 1'b1; end // lhu
                    default: illegal = 1'b1;
                endcase
            end
// ---------------- 存数 ----------------
            OP_STORE: begin
                alu_op   = ALU_ADD;
                imm      = imm_s;
                b_imm    = 1'b1;
                is_store = 1'b1;
                case (f3)
                    3'b000: size = 2'b00;   // sb
                    3'b001: size = 2'b01;   // sh
                    3'b010: size = 2'b10;   // sw
                    default: illegal = 1'b1;
                endcase
            end
// ---------------- 分支 ----------------
            OP_BR: begin
                alu_op = ALU_ADD;       // 分支目标在 top 中由 e_pc_q + e_imm_q 计算
                imm    = imm_b;
                b_imm  = 1'b0;
                case (bf3)
                    3'b000: br = 3'b001; // beq
                    3'b001: br = 3'b010; // bne
                    3'b100: br = 3'b011; // blt
                    3'b101: br = 3'b100; // bge
                    3'b110: br = 3'b101; // bltu
                    3'b111: br = 3'b110; // bgeu
                    default: illegal = 1'b1;
                endcase
            end
// ---------------- 跳转 ----------------
            OP_JAL: begin
                alu_op = ALU_ADD;
                imm    = imm_j;
                jump   = 2'd1;
                reg_we = 1'b1;
            end
            OP_JALR: begin
                alu_op = ALU_ADD;
                imm    = imm_i;
                b_imm  = 1'b1;
                jump   = 2'd2;
                reg_we = 1'b1;
                if (f3 != 3'b000) illegal = 1'b1;
            end
// ---------------- SYSTEM：CSR / ecall / ebreak / mret ----------------
            OP_SYS: begin
                if (f3b == 3'b000) begin
                    case (instr[31:20])
                        12'h000: is_ecall  = 1'b1;
                        12'h001: is_ebreak = 1'b1;
                        12'h302: is_mret   = 1'b1;
                        default: illegal   = 1'b1;
                    endcase
                end else begin
                    is_csr = 1'b1;
                    reg_we = 1'b1;
                end
            end
            default: illegal = 1'b1;
        endcase
    end

endmodule
