// wgt_bank.v —— 权重 bank：64 bit × 4，$readmemh 在综合期固化
// ⚠ .hex 路径相对 PDS 工作目录（pg200h/），故写 ../sw/npu/xxx.hex。

module wgt_bank #(
    parameter WGT_FILE = "../sw/npu/wgt_bank0.hex",
    parameter AW       = 10             // 深度 = 2^AW 个 64 bit 字；单 Bank 8 KB，4 个 Bank 共 32 KB
) (
    input  wire        clk,
    input  wire [15:0] addr,
    output wire [63:0] dout
);

    reg [63:0] m [0:(1<<AW)-1];

    initial $readmemh(WGT_FILE, m);

    reg [63:0] dout_r;
    always @(posedge clk) dout_r <= m[addr[AW-1:0]];

    assign dout = dout_r;

endmodule
