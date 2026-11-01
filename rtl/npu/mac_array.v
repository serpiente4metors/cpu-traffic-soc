// mac_array.v —— 32 路 INT8 MAC 阵列，一拍算 32 个输出通道

module mac_array #(
    parameter N = 32
) (
    input  wire                clk,
    input  wire                rst_n,

    input  wire                step,      // 推进一个 tap（乘 + 累加）
    input  wire                acc_ld,    // 装载累加器初值（偏置/上一组结果）
    input  wire [32*N-1:0]     acc_in,    // acc_ld 时装入的值

    input  wire [7:0]          act,       // 激活，有符号 INT8，广播全 lane
    input  wire [8*N-1:0]      wgt,       // N 个输出通道的权重，有符号 INT8

    output wire [32*N-1:0]     acc,       // 累加器（给 requant 用）
    output wire                step_d1    // "本拍 acc 正在更新"
);

    reg [16*N-1:0] p_q;

// ---------------- 第 2 拍：累加 ----------------
    reg [32*N-1:0] acc_q;

// step 的一拍延迟：p_q 是在 step 拍末尾写入的，
// 下一拍 step_d1=1 才轮到 acc 去吃它。
    reg step_d1_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) step_d1_q <= 1'b0;
        else        step_d1_q <= step;
    end
    assign step_d1 = step_d1_q;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : lane

            wire signed [7:0]  w_s = wgt[8*g +: 8];
            wire signed [7:0]  a_s = act;
            wire signed [15:0] prod = w_s * a_s;

// 打一拍后的部分积（读回来做符号扩展用）
            wire signed [15:0] p_now = p_q[16*g +: 16];

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    p_q[16*g +: 16]   <= 16'd0;
                    acc_q[32*g +: 32] <= 32'd0;
                end else begin
// ---- 第 1 拍 ----
                    if (step) p_q[16*g +: 16] <= prod;

// ---- 第 2 拍 ----
//   acc_ld 优先级最高（装载初值覆盖正在进行的累加）
                    if (acc_ld)
                        acc_q[32*g +: 32] <= acc_in[32*g +: 32];
                    else if (step_d1_q)
// 16 位有符号 → 32 位有符号，再累加（自然回绕，不饱和）
                        acc_q[32*g +: 32] <= acc_q[32*g +: 32]
                                           + {{16{p_now[15]}}, p_now};
                end
            end

            assign acc[32*g +: 32] = acc_q[32*g +: 32];

        end
    endgenerate

endmodule
