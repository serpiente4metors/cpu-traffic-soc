// mul_unit.v —— RV32M 乘法器：4 个 17×17 部分积
// E1 算部分积，E1→E2 打拍后在 E2 拼装与符号修正。

module mul_unit (
    input  wire        clk,
    input  wire        rst_n,

// E1：操作数（组合进，本模块自己在 E1→E2 那级锁存部分积）
    input  wire        iss,          // 本条是 M 扩展乘法
    input  wire [ 2:0] f3,
    input  wire [31:0] a,
    input  wire [31:0] b,

// E2：选出的结果（组合输出，由 top 寄存进 m_alu_q）
    output wire [31:0] y
);

// ---------------- E1：4 个 17×17 部分积（并行，各 1 个 APM）----------------
    wire [16:0] a0 = {1'b0, a[15: 0]};
    wire [16:0] a1 = {1'b0, a[31:16]};
    wire [16:0] b0 = {1'b0, b[15: 0]};
    wire [16:0] b1 = {1'b0, b[31:16]};

    wire [33:0] p00 = a0 * b0;
    wire [33:0] p01 = a0 * b1;
    wire [33:0] p10 = a1 * b0;
    wire [33:0] p11 = a1 * b1;

// ---------------- E1 -> E2 ----------------
    reg        iss_q;
    reg [ 2:0] f3_q;
    reg [31:0] a_q, b_q;             // 符号位 + 无符号值都要用
    reg [33:0] p00_q, p01_q, p10_q, p11_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            iss_q <= 1'b0;
            f3_q  <= 3'd0;
            a_q   <= 32'd0;  b_q  <= 32'd0;
            p00_q <= 34'd0;  p01_q <= 34'd0;
            p10_q <= 34'd0;  p11_q <= 34'd0;
        end else begin
            iss_q <= iss;
            f3_q  <= f3;
            a_q   <= a;
            b_q   <= b;
            p00_q <= p00;
            p01_q <= p01;
            p10_q <= p10;
            p11_q <= p11;
        end
    end

    wire [63:0] hi  = {32'd0, p11_q[31:0]} << 32;
    wire [63:0] mid = {14'd0, p01_q, 16'd0} + {14'd0, p10_q, 16'd0};
    wire [63:0] U   = hi + mid + {30'd0, p00_q};

// ---------------- E2：符号修正 ----------------
    wire [63:0] corr_a = a_q[31] ? {b_q, 32'd0} : 64'd0;
    wire [63:0] corr_b = b_q[31] ? {a_q, 32'd0} : 64'd0;

    wire [63:0] S    = U - corr_a - corr_b;   // signed × signed
    wire [63:0] SU   = U - corr_a;            // signed × unsigned

    assign y = (f3_q == 3'b001) ? S [63:32] :   // MULH
               (f3_q == 3'b010) ? SU[63:32] :   // MULHSU
               (f3_q == 3'b011) ? U [63:32] :   // MULHU
                                  U [31: 0] ;   // MUL

endmodule
