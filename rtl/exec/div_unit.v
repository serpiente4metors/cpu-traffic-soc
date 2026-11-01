// div_unit.v —— RV32M 除法器：恢复余数法，每拍出 1 位，共 32 拍

module div_unit (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        ack,          // 取走结果（指令离开 E1）→ 清 valid
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire        is_signed,     // 1 = div/rem（有符号），0 = divu/remu
    input  wire        want_rem,      // 1 = 取余数

    output wire        busy,
    output wire        valid,
    output wire [31:0] result
);

    reg        busy_q, valid_q;
    reg        sa_q;                  // 被除数符号（余数取它）
    reg        negq_q;                // 商的符号
    reg        rem_mode_q;
    reg        zero_q, ovf_q;
    reg [31:0] quo_q;                 // 移位寄存器：先装被除数，最后装商
    reg [32:0] rem_q;
    reg [32:0] bm_q;                  // |b|
    reg [31:0] a_orig_q;
    reg [ 5:0] cnt_q;

    wire [31:0] a_mag = (is_signed && a[31]) ? (~a + 32'd1) : a;
    wire [31:0] b_mag = (is_signed && b[31]) ? (~b + 32'd1) : b;

    wire [32:0] rem_shift = {rem_q[31:0], quo_q[31]};
    wire        ge        = (rem_shift >= bm_q);
    wire [32:0] rem_next  = ge ? (rem_shift - bm_q) : rem_shift;

    assign busy   = busy_q;
    assign valid  = valid_q;

// 结果组合选择
    wire [31:0] quo_fix = negq_q ? (~quo_q + 32'd1) : quo_q;
    wire [31:0] rem_fix = sa_q   ? (~rem_q[31:0] + 32'd1) : rem_q[31:0];

    assign result = zero_q ? (rem_mode_q ? a_orig_q : 32'hFFFF_FFFF) :
                    ovf_q  ? (rem_mode_q ? 32'd0 : 32'h8000_0000) :
                    rem_mode_q ? rem_fix : quo_fix;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy_q <= 1'b0; valid_q <= 1'b0;
            sa_q <= 1'b0; negq_q <= 1'b0; rem_mode_q <= 1'b0;
            zero_q <= 1'b0; ovf_q <= 1'b0;
            quo_q <= 32'd0; rem_q <= 33'd0; bm_q <= 33'd0;
            a_orig_q <= 32'd0; cnt_q <= 6'd0;
        end else if (start) begin
            busy_q     <= 1'b1;
            valid_q    <= 1'b0;
            sa_q       <= is_signed && a[31];
            negq_q     <= is_signed && (a[31] ^ b[31]);
            rem_mode_q <= want_rem;
            zero_q     <= (b == 32'd0);
            ovf_q      <= is_signed && (a == 32'h8000_0000) && (b == 32'hFFFF_FFFF);
            quo_q      <= a_mag;
            rem_q      <= 33'd0;
            bm_q       <= {1'b0, b_mag};
            a_orig_q   <= a;
            cnt_q      <= 6'd32;
        end else if (valid_q && ack) begin
            valid_q <= 1'b0;          // 结果被取走，允许下一条除法重新 start
        end else if (busy_q) begin
            quo_q <= {quo_q[30:0], ge};
            rem_q <= rem_next;
            cnt_q <= cnt_q - 6'd1;
            if (cnt_q == 6'd1) begin
                busy_q  <= 1'b0;
                valid_q <= 1'b1;
            end
        end
    end

endmodule
