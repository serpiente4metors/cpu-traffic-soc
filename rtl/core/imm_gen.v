// imm_gen.v —— RV32I 五种立即数并行输出，由 ctrl_unit 选用哪一路

module imm_gen (
    input  wire [31:0] instr,

    output wire [31:0] imm_i,   // addi / load / jalr
    output wire [31:0] imm_s,   // store
    output wire [31:0] imm_b,   // branch
    output wire [31:0] imm_u,   // lui / auipc
    output wire [31:0] imm_j    // jal
);

    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7],
                    instr[30:25], instr[11:8], 1'b0};
    assign imm_u = {instr[31:12], 12'b0};
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12],
                    instr[20], instr[30:21], 1'b0};

endmodule
