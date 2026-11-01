// npu_addrgen.v —— 卷积地址生成：按 tap / 行 / 通道给出读写地址与边界标志

module npu_addrgen (
    input  wire        clk,
    input  wire        rst_n,

// ---- 控制脉冲 ----
    input  wire        begin_ld,      // CONV_BEGIN：锁存层描述符 + 像素迭代归零
    input  wire        tap_clr,       // ACC_CLR：tap 计数器归零（保留 oh/ow）
    input  wire        tap_go,        // 推进一个 tap
    input  wire        pix_next,      // 输出像素推进
    input  wire        pb_ld,         // 像素基址重装（CONV_BEGIN 第二拍）

// ---- 层描述符（npu_core 里的影子寄存器）----
    input  wire [16:0] img_base,
    input  wire [15:0] img_w,
    input  wire [15:0] img_h,
    input  wire [15:0] cin,
    input  wire [15:0] cout,          // 只用来推进输出写指针
    input  wire [15:0] k,
    input  wire [15:0] stride,
    input  wire [15:0] pad,
    input  wire [15:0] out_w,
    input  wire [15:0] out_h,
    input  wire [16:0] out_base,
    input  wire [15:0] wgt_base,

// ---- 输出 ----
    output wire [16:0] act_addr,      // 窗口内字节偏移（越界时无意义）
    output wire        act_valid,     // 0 = 该 tap 是 padding，要用 0
    output wire [15:0] wgt_idx,       // 权重 tap 序号（已含 wgt_base）
    output wire [15:0] tap_len,       // 一个像素要跑多少 tap = k*k*cin
    output wire        tap_last,      // 当前是最后一个 tap
    output wire [16:0] out_ptr        // 输出写指针（窗口内字节偏移）
);

    reg [16:0] row_bytes;      // img_w * cin
    reg [16:0] row_x2;         // 2 * row_bytes
    reg [16:0] cin_x2;         // 2 * cin

    wire [16:0] kk    = k * k;              // k<=3 时取 1、4 或 9
    wire [16:0] tlen  = kk * cin;           // 一个像素的 tap 总数

    assign tap_len = tlen;

    reg [15:0] oh, ow;         // 输出像素坐标
    reg [15:0] kh, kw;         // 核内位置
    reg [15:0] ic;             // 输入通道
    reg [15:0] widx;           // 权重 tap 序号
    reg [16:0] pix_base;       // 该像素 (kh=0,kw=0) 的激活基址
    reg [16:0] outptr_q;       // 输出写指针

    assign out_ptr = outptr_q;

// ---- 像素推进后的坐标（用于预先算好下一个像素的 pix_base）----
    wire [15:0] ow_n = (ow + 16'd1 >= out_w) ? 16'd0 : (ow + 16'd1);
    wire [15:0] oh_n = (ow + 16'd1 >= out_w) ? ((oh + 16'd1 >= out_h) ? 16'd0 : (oh + 16'd1)) : oh;

// stride 只允许 1/2（npu_core 的 cfg_bad 会拒绝其它值）。
// 用移位/选择代替 16x16 乘法，缩短 BRAM 地址前的组合路径。
    wire [16:0] oh_s   = (stride == 16'd2) ? ({1'b0, oh}   << 1) : {1'b0, oh};
    wire [16:0] ow_s   = (stride == 16'd2) ? ({1'b0, ow}   << 1) : {1'b0, ow};
    wire [16:0] oh_n_s = (stride == 16'd2) ? ({1'b0, oh_n} << 1) : {1'b0, oh_n};
    wire [16:0] ow_n_s = (stride == 16'd2) ? ({1'b0, ow_n} << 1) : {1'b0, ow_n};

    wire [16:0] y0n_raw = oh_n_s;
    wire [16:0] x0n_raw = ow_n_s;
    wire [16:0] y0n     = y0n_raw - {1'b0, pad};
    wire [16:0] x0n     = x0n_raw - {1'b0, pad};

    reg [16:0] y0n_q, x0n_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            y0n_q <= 17'd0;
            x0n_q <= 17'd0;
        end else begin
            y0n_q <= y0n;
            x0n_q <= x0n;
        end
    end

    reg [16:0] pb_nxt_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pb_nxt_q <= 17'd0;
        else        pb_nxt_q <= img_base + y0n_q * row_bytes + x0n_q * {1'b0, cin};
    end

    reg [16:0] pb_first_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) pb_first_q <= 17'd0;
        else        pb_first_q <= img_base - {1'b0, pad} * row_bytes - {1'b0, pad} * {1'b0, cin};
    end

    wire [16:0] ih_raw = oh_s + {1'b0, kh};
    wire [16:0] iw_raw = ow_s + {1'b0, kw};

    wire [16:0] ih_p = ih_raw - {1'b0, pad};
    wire [16:0] iw_p = iw_raw - {1'b0, pad};

    wire ih_ok = (ih_raw >= {1'b0, pad}) && (ih_p < {1'b0, img_h});
    wire iw_ok = (iw_raw >= {1'b0, pad}) && (iw_p < {1'b0, img_w});

    assign act_valid = ih_ok && iw_ok;

    wire [16:0] kh_off = (kh == 16'd0) ? 17'd0 :
                         (kh == 16'd1) ? row_bytes : row_x2;
    wire [16:0] kw_off = (kw == 16'd0) ? 17'd0 :
                         (kw == 16'd1) ? {1'b0, cin} : cin_x2;

    assign act_addr = pix_base + kh_off + kw_off + {1'b0, ic};

// 权重序号 = wgt_base + (kh*k + kw)*cin + ic，其中 (kh*k+kw)*cin+ic 就是 tap 计数
    assign wgt_idx = wgt_base + widx;

    assign tap_last = (widx + 16'd1 >= tlen);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            row_bytes <= 17'd0;
            row_x2    <= 17'd0;
            cin_x2    <= 17'd0;
            oh        <= 16'd0;
            ow        <= 16'd0;
            kh        <= 16'd0;
            kw        <= 16'd0;
            ic        <= 16'd0;
            widx      <= 16'd0;
            pix_base  <= 17'd0;
            outptr_q  <= 17'd0;
        end else if (begin_ld) begin
// ---- CONV_BEGIN：每层一次 ----
            row_bytes <= {1'b0, img_w} * {1'b0, cin};
            row_x2    <= {1'b0, img_w} * {1'b0, cin} * 2;
            cin_x2    <= {1'b0, cin} * 2;
            oh        <= 16'd0;
            ow        <= 16'd0;
            kh        <= 16'd0;
            kw        <= 16'd0;
            ic        <= 16'd0;
            widx      <= 16'd0;
// 装 (0,0) 像素基址
            outptr_q  <= out_base;
        end else begin
// ---- ACC_CLR：tap 迭代归零，像素坐标保留 ----
            if (tap_clr) begin
                kh   <= 16'd0;
                kw   <= 16'd0;
                ic   <= 16'd0;
                widx <= 16'd0;
            end else if (tap_go) begin
                if (ic + 16'd1 >= cin) begin
                    ic <= 16'd0;
                    if (kw + 16'd1 >= k) begin
                        kw <= 16'd0;
                        kh <= (kh + 16'd1 >= k) ? 16'd0 : (kh + 16'd1);
                    end else begin
                        kw <= kw + 16'd1;
                    end
                end else begin
                    ic <= ic + 16'd1;
                end
                widx <= widx + 16'd1;
            end

// ---- 像素基址重装（CONV_BEGIN 第二拍，(0,0) 像素）----
            if (pb_ld) begin
                pix_base <= pb_first_q;
            end

// ---- 下一个输出像素 ----
            if (pix_next) begin
                ow       <= ow_n;
                oh       <= oh_n;
                pix_base <= pb_nxt_q;
                outptr_q <= outptr_q + {1'b0, cout};
            end
        end
    end

endmodule
