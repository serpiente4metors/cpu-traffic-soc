// npu_regs.v —— 加速器 MMIO 寄存器，地址相对 0x1000_0000
// 0x10 CTRL / 0x14 STAT / 0x1C IMG / 0x20 WGT / 0x24 OUT
// 0x38..0x5C 形状与 shift / 0x60..0x9C M[0..31] / 0xA4..0xAC bias 等

module npu_regs (
    input  wire        clk,
    input  wire        rst_n,

// ---- 来自 top.v 的 MMIO 访问 ----
    input  wire        wr,          // 单拍写脉冲（已门控）
    input  wire [ 7:0] addr,        // e2_maddr[7:0]
    input  wire [31:0] wdata,       // e2_mstdata（未移位）
    output reg  [31:0] rdata,

// ---- 给引擎的控制 ----
    output wire        start_pulse,
    output wire        soft_rst_pulse,
    output wire        abort_pulse,
    output wire        npu_irq,
    output wire        busy_o,      // = busy_i | sw_busy_q，给 top.v 做访存防呆

// ---- 配置寄存器 ----
    output reg  [31:0] irq_en,
    output reg  [31:0] img_base,
    output reg  [31:0] wgt_base,
    output reg  [31:0] out_base,

// ---- 层描述符（S4）----
    output reg  [15:0] img_w,
    output reg  [15:0] img_h,
    output reg  [15:0] cin,
    output reg  [15:0] cout,
    output reg  [15:0] ker,
    output reg  [15:0] stride,
    output reg  [15:0] pad,
    output reg  [15:0] out_w,
    output reg  [15:0] out_h,
    output reg  [ 4:0] shift,
    output reg  [511:0] mbank,      // 32 lane × 16 bit
// ---- S4.1：bias / ReLU ----
    output reg  [32*32-1:0] bias_flat, // 32 lane × 32 bit
    output reg              act,

// ---- 引擎回送 ----
    input  wire        busy_i,
    input  wire        done_set_i,
    input  wire        err_set_i,
    input  wire [31:0] cycle_i,
    input  wire [ 3:0] state_i
);

    reg [4:0] bias_idx;         // 当前 bias 写指针（自增）

    wire wr_ctrl = wr && (addr == 8'h10);
    wire wr_stat = wr && (addr == 8'h14);

    wire self_done = wr_ctrl && wdata[3];   // SW_DONE：把 DONE 置起来
    wire clr_done  = wr_stat && wdata[1];   // W1C：写 1 清 DONE
    wire clr_err   = wr_stat && wdata[2];   // W1C：写 1 清 ERROR

    reg done_q, err_q, sw_busy_q;

    wire [7:0] m_off = addr - 8'h60;
    wire       m_hit = (addr >= 8'h60) && (addr <= 8'h9C) && (addr[1:0] == 2'b00);
    wire [3:0] m_idx = m_off[5:2];

    wire busy_w = busy_i | sw_busy_q;
    assign busy_o = busy_w;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_q <= 1'b0;
            err_q  <= 1'b0;
        end else begin
            if (done_set_i || self_done) done_q <= 1'b1;
            else if (clr_done)           done_q <= 1'b0;

            if (err_set_i) err_q <= 1'b1;
            else if (clr_err) err_q <= 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                   sw_busy_q <= 1'b0;
        else if (soft_rst_pulse)      sw_busy_q <= 1'b0;
        else if (wr_ctrl && wdata[4]) sw_busy_q <= 1'b1;
        else if (wr_ctrl && wdata[5]) sw_busy_q <= 1'b0;
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_en   <= 32'd0;
            img_base <= 32'd0;
            wgt_base <= 32'd0;
            out_base <= 32'd0;
            img_w    <= 16'd0;
            img_h    <= 16'd0;
            cin      <= 16'd0;
            cout     <= 16'd0;
            ker      <= 16'd0;
            stride   <= 16'd0;
            pad      <= 16'd0;
            out_w    <= 16'd0;
            out_h    <= 16'd0;
            shift    <= 5'd0;
            mbank    <= 512'd0;
            bias_flat <= 1024'd0;
            bias_idx  <= 5'd0;
            act       <= 1'b0;
        end else if (wr) begin
            if (addr == 8'h18) irq_en   <= wdata;
            if (addr == 8'h1C) img_base <= wdata;
            if (addr == 8'h20) wgt_base <= wdata;
            if (addr == 8'h24) out_base <= wdata;
            if (addr == 8'h38) img_w    <= wdata[15:0];
            if (addr == 8'h3C) img_h    <= wdata[15:0];
            if (addr == 8'h40) cin      <= wdata[15:0];
            if (addr == 8'h44) cout     <= wdata[15:0];
            if (addr == 8'h48) ker      <= wdata[15:0];
            if (addr == 8'h4C) stride   <= wdata[15:0];
            if (addr == 8'h50) pad      <= wdata[15:0];
            if (addr == 8'h54) out_w    <= wdata[15:0];
            if (addr == 8'h58) out_h    <= wdata[15:0];
            if (addr == 8'h5C) shift    <= wdata[4:0];
// M[2i] 在低 16 位，M[2i+1] 在高 16 位
            if (m_hit) mbank[{m_idx, 5'b00000} +: 32] <= wdata;
// bias：写一个 lane 后指针自增，CPU 只要设一次 IDX 再连写 32 个字
            if (addr == 8'hA4) begin
                bias_flat[{bias_idx, 5'b00000} +: 32] <= wdata;
                bias_idx <= bias_idx + 5'd1;
            end
            if (addr == 8'hA8) bias_idx <= wdata[4:0];
            if (addr == 8'hAC) act      <= wdata[0];
        end
    end

    assign start_pulse    = wr_ctrl && wdata[0];
    assign soft_rst_pulse = wr_ctrl && wdata[1];
    assign abort_pulse    = wr_ctrl && wdata[2];
    assign npu_irq        = done_q && irq_en[0];

    always @(*) begin
        case (addr)
            8'h10:   rdata = 32'd0;
            8'h14:   rdata = {24'd0, state_i, 1'b0, err_q, done_q, busy_w};
            8'h18:   rdata = irq_en;
            8'h1C:   rdata = img_base;
            8'h20:   rdata = wgt_base;
            8'h24:   rdata = out_base;
            8'h28:   rdata = cycle_i;
            8'h2C:   rdata = 32'h0001_0000;
            8'h30:   rdata = 32'd0;
            8'h34:   rdata = {28'd0, state_i};
            8'h38:   rdata = {16'd0, img_w};
            8'h3C:   rdata = {16'd0, img_h};
            8'h40:   rdata = {16'd0, cin};
            8'h44:   rdata = {16'd0, cout};
            8'h48:   rdata = {16'd0, ker};
            8'h4C:   rdata = {16'd0, stride};
            8'h50:   rdata = {16'd0, pad};
            8'h54:   rdata = {16'd0, out_w};
            8'h58:   rdata = {16'd0, out_h};
            8'h5C:   rdata = {27'd0, shift};
            8'hA0:   rdata = 32'h0000_0007;   // CAP: 引擎 + 固化权重 + 输出通道并行
            8'hA8:   rdata = {27'd0, bias_idx};
            8'hAC:   rdata = {31'd0, act};
            8'hB0:   rdata = mbank[32*(0)+:32];  // 此行仅为占位，下面统一覆盖
            default: rdata = 32'd0;
        endcase
        if (addr >= 8'h60 && addr <= 8'h9C && addr[1:0] == 2'b00)
            rdata = mbank[({1'b0, addr[6:2]} * 32) +: 32];
    end

endmodule
