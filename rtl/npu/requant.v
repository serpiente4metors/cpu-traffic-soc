// requant.v —— 重量化：acc32 × M16 >>> s，加偏置后饱和到 INT8

module requant #(
    parameter N = 32
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                en,        // 输入有效
    input  wire [32*N-1:0]     acc,       // 有符号累加值
    input  wire [16*N-1:0]     m,         // 无符号乘数，per lane
    input  wire [4:0]          s,         // 右移位数，全局共用

    output wire [8*N-1:0]      y,         // INT8 结果
    output wire                y_valid
);

// ---------------- 第 A 拍：乘法 ----------------
    reg [48*N-1:0] prod_q;

// ---------------- 第 B 拍：移位 + 饱和 ----------------
    reg [8*N-1:0]  y_q;

// 有效位与移位量都要跟着数据一起走两拍
    reg            v1_q, v2_q;
    reg  [4:0]     s_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1_q <= 1'b0;
            v2_q <= 1'b0;
            s_q  <= 5'd0;
        end else begin
            v1_q <= en;
            v2_q <= v1_q;
            if (en) s_q <= s;       // 与第 A 拍的数据一起对齐
        end
    end

    assign y_valid = v2_q;

// 饱和函数：48 位有符号 → 8 位有符号
    function signed [7:0] sat8 (input signed [47:0] v);
        begin
            if (v > 48'sd127)
                sat8 = 8'sd127;
            else if (v < -48'sd128)
                sat8 = -8'sd128;
            else
                sat8 = v[7:0];
        end
    endfunction

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : lane

            wire signed [31:0] acc_s = acc[32*g +: 32];
// M 是无符号 16 位，前面补一个 0 变成 17 位有符号正数再参与乘法
            wire signed [16:0] m_s   = {1'b0, m[16*g +: 16]};
            wire signed [47:0] prod  = acc_s * m_s;

            wire signed [47:0] p_now = prod_q[48*g +: 48];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    prod_q[48*g +: 48] <= 48'd0;
                    y_q[8*g +: 8]      <= 8'd0;
                end else begin
// ---- 第 A 拍 ----
                    if (en) prod_q[48*g +: 48] <= prod;

// ---- 第 B 拍 ----
//   >>> 是算术右移（负数下取整），与 Python 的 >> 语义一致。
                    if (v1_q) y_q[8*g +: 8] <= sat8(p_now >>> s_q);
                end
            end

            assign y[8*g +: 8] = y_q[8*g +: 8];

        end
    endgenerate

endmodule
