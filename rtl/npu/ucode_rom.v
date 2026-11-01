// ucode_rom.v —— NPU 微码 ROM，组合读
// 指令 32 bit：[31:26] op [25:21] a [20:16] b [15:0] imm

module ucode_rom (
    input  wire [ 3:0] addr,
    output reg  [31:0] ins
);

// op 编码（和 npu_设计.md §8 的表对齐）
    localparam OP_NOP        = 6'h00;
    localparam OP_WGT_SET    = 6'h01;
    localparam OP_ACT_SET    = 6'h02;
    localparam OP_ACC_CLR    = 6'h03;
    localparam OP_MAC        = 6'h04;
    localparam OP_TREE       = 6'h05;   // S4 保留，输出通道并行用不上
    localparam OP_REQ        = 6'h06;
    localparam OP_ST_OUT     = 6'h07;
    localparam OP_POOL2      = 6'h08;   // S5
    localparam OP_ACTV       = 6'h09;   // S5
    localparam OP_LOOP       = 6'h0A;
    localparam OP_END        = 6'h0B;
    localparam OP_OUT_SET    = 6'h0C;   // 扩展：输出基址（也可以走 MMIO）
    localparam OP_PIX_NEXT   = 6'h0D;   // 扩展：推进输出像素
    localparam OP_CONV_BEGIN = 6'h0F;   // 扩展：锁层描述符

// 打包：{op, dst, src, imm16}
    function [31:0] I;
        input [5:0]  op;
        input [4:0]  dst;
        input [4:0]  src;
        input [15:0] imm;
        begin
            I = {op, dst, src, imm};
        end
    endfunction

    always @(*) begin
        case (addr)
            4'd0: ins = I(OP_CONV_BEGIN, 5'd0, 5'd0, 16'd0);
            4'd1: ins = I(OP_ACC_CLR,    5'd0, 5'd0, 16'd0);
            4'd2: ins = I(OP_MAC,        5'd0, 5'd0, 16'd0);   // 自动 k*k*cin
            4'd3: ins = I(OP_REQ,        5'd0, 5'd0, 16'd0);   // 自动取 SHIFT
            4'd4: ins = I(OP_ST_OUT,     5'd0, 5'd0, 16'd0);
            4'd5: ins = I(OP_PIX_NEXT,   5'd0, 5'd0, 16'd0);
            4'd6: ins = I(OP_LOOP,       5'd1, 5'd0, 16'd0);   // 跳回 1，次数自动
            4'd7: ins = I(OP_END,        5'd0, 5'd0, 16'd0);
            default: ins = I(OP_END,     5'd0, 5'd0, 16'd0);
        endcase
    end

endmodule
