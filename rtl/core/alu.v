// alu.v —— 组合 ALU（加/减/逻辑/比较/移位）
// alu_op 编码须与 ctrl_unit.v 中的 localparam 保持一致。

module alu #(
    parameter ALU_ADD    = 4'd0,
    parameter ALU_SUB    = 4'd1,
    parameter ALU_SLL    = 4'd2,
    parameter ALU_SLT    = 4'd3,
    parameter ALU_SLTU   = 4'd4,
    parameter ALU_XOR    = 4'd5,
    parameter ALU_SRL    = 4'd6,
    parameter ALU_SRA    = 4'd7,
    parameter ALU_OR     = 4'd8,
    parameter ALU_AND    = 4'd9,
    parameter ALU_PASS_B = 4'd10
) (
    input  wire [ 3:0] alu_op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);

    wire [4:0] sh = b[4:0];

    wire [32:0] diff  = {1'b0, a} - {1'b0, b};

// ---- 比较结果直接从同一条链出来 ----
    wire        slt_u = diff[32];                                  // 无符号 a < b
    wire        slt_s = (a[31] & ~b[31]) |
                        (~(a[31] ^ b[31]) & diff[31]);             // 有符号 a < b

    always @* begin
        case (alu_op)
            ALU_ADD   : y = a + b;
            ALU_SUB   : y = diff[31:0];
            ALU_SLL   : y = a << sh;
            ALU_SLT   : y = {31'd0, slt_s};
            ALU_SLTU  : y = {31'd0, slt_u};
            ALU_XOR   : y = a ^ b;
            ALU_SRL   : y = a >> sh;
            ALU_SRA   : y = $signed(a) >>> sh;
            ALU_OR    : y = a | b;
            ALU_AND   : y = a & b;
            ALU_PASS_B: y = b;
            default   : y = 32'd0;
        endcase
    end

endmodule
