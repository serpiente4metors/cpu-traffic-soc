// npu_core.v —— INT8 卷积加速器：微码 + 地址生成 + MAC + 重量化 + 写回
// 所有层参数在综合期固化，运行时无动态调度。

module npu_core #(
// 权重文件路径相对 PDS 综合工作目录（pg200h/），与 top_fpga 的 MEM_FILE 同一套约定
    parameter WGT_FILE0 = "../sw/npu/wgt_bank0.hex",
    parameter WGT_FILE1 = "../sw/npu/wgt_bank1.hex",
    parameter WGT_FILE2 = "../sw/npu/wgt_bank2.hex",
    parameter WGT_FILE3 = "../sw/npu/wgt_bank3.hex",
    parameter WGT_AW    = 10
) (
    input  wire         clk,
    input  wire         rst_n,

// ---------------- MMIO 控制 ----------------
    input  wire         start,          // 单拍启动
    input  wire         soft_rst,
    input  wire         abort,
    output wire         busy,
    output wire         done_pulse,     // 单拍完成
    output wire         err_pulse,      // 单拍配置错误
    output wire [ 3:0]  state_o,
    output wire [31:0]  cycle_o,

// ---------------- 层描述符 ----------------
    input  wire [16:0]  cfg_img_base,
    input  wire [16:0]  cfg_out_base,
    input  wire [15:0]  cfg_wgt_base,
    input  wire [15:0]  cfg_img_w,
    input  wire [15:0]  cfg_img_h,
    input  wire [15:0]  cfg_cin,
    input  wire [15:0]  cfg_cout,
    input  wire [15:0]  cfg_k,
    input  wire [15:0]  cfg_stride,
    input  wire [15:0]  cfg_pad,
    input  wire [15:0]  cfg_out_w,
    input  wire [15:0]  cfg_out_h,
    input  wire [ 4:0]  cfg_shift,
    input  wire [511:0] cfg_mbank,      // 32 lane × 16 bit 重量化乘数
    input  wire [32*32-1:0] cfg_bias,   // S4.1：32 lane × 32 bit 卷积偏置
    input  wire         cfg_act,        // S4.1：1 = 重量化后 ReLU

// ---------------- 主存 B 口（窗口内字节偏移）----------------
    output wire         mem_use,        // 1 = NPU 正在占用 B 口
    output wire [16:0]  mem_raddr,
    input  wire [31:0]  mem_rdata,      // 含目标字节的 32 位对齐字
    output wire         mem_we,
    output wire [16:0]  mem_waddr,
    output wire [63:0]  mem_wdata,
    output wire [ 7:0]  mem_wstrb
);

    localparam N = 32;

    localparam ST_IDLE   = 4'd0,
               ST_DISP   = 4'd1,
               ST_BEGIN  = 4'd2,
               ST_BEGIN2 = 4'd10,
               ST_MAC    = 4'd3,
               ST_MACEND = 4'd4,
               ST_REQW   = 4'd5,
               ST_REQW2  = 4'd6,
               ST_ST     = 4'd7,
               ST_LOOP   = 4'd8,
               ST_END    = 4'd9;

    reg [3:0] st;

    reg  [ 3:0] pc;
    wire [31:0] ins;
    wire [ 5:0] op  = ins[31:26];
    wire [ 4:0] dst = ins[25:21];
    wire [15:0] imm = ins[15:0];

    ucode_rom u_rom (.addr(pc), .ins(ins));

    localparam OP_NOP        = 6'h00;
    localparam OP_ACC_CLR    = 6'h03;
    localparam OP_MAC        = 6'h04;
    localparam OP_REQ        = 6'h06;
    localparam OP_ST_OUT     = 6'h07;
    localparam OP_LOOP       = 6'h0A;
    localparam OP_END        = 6'h0B;
    localparam OP_PIX_NEXT   = 6'h0D;
    localparam OP_CONV_BEGIN = 6'h0F;

    wire        tap_go, pix_next;
    wire [16:0] act_addr;
    wire        act_valid;
    wire [15:0] wgt_idx, tap_len;
    wire [16:0] out_ptr;

// CONV_BEGIN / ACC_CLR 的装载脉冲只在对应指令那一拍有效
    wire begin_ld = (st == ST_DISP) && (op == OP_CONV_BEGIN);
    wire tap_clr  = (st == ST_DISP) && (op == OP_ACC_CLR);
    assign pix_next = (st == ST_DISP) && (op == OP_PIX_NEXT);
    assign tap_go   = (st == ST_MAC);
    wire   pb_ld    = (st == ST_BEGIN2);  // CONV_BEGIN 第二拍装载 (0,0) 像素基址

    npu_addrgen u_ag (
        .clk       (clk),
        .rst_n     (rst_n),
        .begin_ld  (begin_ld),
        .tap_clr   (tap_clr),
        .tap_go    (tap_go),
        .pix_next  (pix_next),
        .pb_ld     (pb_ld),
        .img_base  (cfg_img_base),
        .img_w     (cfg_img_w),
        .img_h     (cfg_img_h),
        .cin       (cfg_cin),
        .cout      (cfg_cout),
        .k         (cfg_k),
        .stride    (cfg_stride),
        .pad       (cfg_pad),
        .out_w     (cfg_out_w),
        .out_h     (cfg_out_h),
        .out_base  (cfg_out_base),
        .wgt_base  (cfg_wgt_base),
        .act_addr  (act_addr),
        .act_valid (act_valid),
        .wgt_idx   (wgt_idx),
        .tap_len   (tap_len),
        .tap_last  (),
        .out_ptr   (out_ptr)
    );

    reg  [16:0] act_addr_q;
    reg         act_valid_q;
    reg  [15:0] wgt_idx_q;
    reg         tap_go_q;

    wire [63:0] wb0, wb1, wb2, wb3;

    wgt_bank #(.WGT_FILE(WGT_FILE0), .AW(WGT_AW)) u_b0
        (.clk(clk), .addr(wgt_idx_q), .dout(wb0));
    wgt_bank #(.WGT_FILE(WGT_FILE1), .AW(WGT_AW)) u_b1
        (.clk(clk), .addr(wgt_idx_q), .dout(wb1));
    wgt_bank #(.WGT_FILE(WGT_FILE2), .AW(WGT_AW)) u_b2
        (.clk(clk), .addr(wgt_idx_q), .dout(wb2));
    wgt_bank #(.WGT_FILE(WGT_FILE3), .AW(WGT_AW)) u_b3
        (.clk(clk), .addr(wgt_idx_q), .dout(wb3));

    wire [8*N-1:0] wgt_rom = {wb3, wb2, wb1, wb0};

    wire [32*N-1:0] acc;
    wire            step_d1;
    wire [8*N-1:0]  y;
    wire            y_valid;

// S4.1：ReLU 在 requant 之后、写回之前。y 是有符号 int8，
// 最高位为 1 即负数，直接清 0；否则原样通过。
    wire [8*N-1:0]  y_act;
    genvar gi;
    generate
        for (gi = 0; gi < N; gi = gi + 1) begin : gen_relu
            assign y_act[8*gi +: 8] = (cfg_act && y[8*gi+7]) ? 8'd0 : y[8*gi +: 8];
        end
    endgenerate

    reg            acc_ld;
    reg            rq_en;
// 这三个必须先声明（下面 mac_array 的端口要用；晚声明会变成 1 位隐式线网）
    reg            step;
    reg  [ 7:0]    act_b;
    reg  [8*N-1:0] wgt_b;

    mac_array #(.N(N)) u_mac (
        .clk     (clk),
        .rst_n   (rst_n),
        .step    (step),
        .acc_ld  (acc_ld),
        .acc_in  (cfg_bias),            // S4.1：ACC_CLR 装 bias，不再恒 0
        .act     (act_b),
        .wgt     (wgt_b),
        .acc     (acc),
        .step_d1 (step_d1)
    );

    requant #(.N(N)) u_rq (
        .clk     (clk),
        .rst_n   (rst_n),
        .en      (rq_en),
        .acc     (acc),
        .m       (cfg_mbank),
        .s       (cfg_shift),
        .y       (y),
        .y_valid (y_valid)
    );

    reg           ok1_q, okv_q;
    reg  [ 1:0]   sel1_q;

    wire [7:0] mem_byte = mem_rdata[{sel1_q, 3'b000} +: 8];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ok1_q  <= 1'b0;
            okv_q  <= 1'b0;
            sel1_q <= 2'd0;
            act_b  <= 8'd0;
            wgt_b  <= {8*N{1'b0}};
            step   <= 1'b0;
            act_addr_q  <= 17'd0;
            act_valid_q <= 1'b0;
            wgt_idx_q   <= 16'd0;
            tap_go_q    <= 1'b0;
        end else begin
            act_addr_q  <= act_addr;
            act_valid_q <= act_valid;
            wgt_idx_q   <= wgt_idx;
            tap_go_q    <= tap_go;

// t+1：主存/bank 的同步输出已就绪
            ok1_q  <= tap_go_q;
            okv_q  <= act_valid_q;      // 与打拍后的地址严格对齐
            sel1_q <= act_addr_q[1:0];

// t+1 采、t+2 有效：数据和 step 一起对齐
            act_b <= (ok1_q && okv_q) ? mem_byte : 8'd0;
            wgt_b <= wgt_rom;
            step  <= ok1_q;
        end
    end

    reg [15:0] mac_cnt;        // 剩余 tap 数
    reg [15:0] st_cnt;         // 当前写第几个 64 bit 字
    reg [15:0] loop_cnt;       // LOOP 剩余次数
    reg        busy_q;
    reg [31:0] cyc_q;
    reg        done_q, err_q;

    assign busy       = busy_q;
    assign state_o    = st;
    assign cycle_o    = cyc_q;
    assign done_pulse = done_q;
    assign err_pulse  = err_q;

// B 口占用：只有发读地址和写这两段
    assign mem_use   = busy_q && ((st == ST_MAC) || (st == ST_MACEND) || (st == ST_ST));
    assign mem_raddr = act_valid_q ? act_addr_q : cfg_img_base;

    assign mem_we    = (st == ST_ST);
    assign mem_waddr = out_ptr + {10'd0, st_cnt, 3'b000};
    assign mem_wdata = y_act[{st_cnt[1:0], 6'b000000} +: 64];
    assign mem_wstrb = ({1'b0, st_cnt, 3'b000} < {1'b0, cfg_cout}) ? 8'hFF : 8'h00;

// 一个像素要跑多少 tap；一次写多少字；循环多少次
    wire [15:0] mac_len  = (imm == 16'd0) ? tap_len : imm;
    wire [15:0] nwords   = cfg_cout[15:3];
    wire [16:0] loop_len = (imm == 16'd0) ? (cfg_out_w * cfg_out_h) : {1'b0, imm};

// 配置合法性（启动时查一次）
    wire cfg_bad = (cfg_cout[2:0] != 3'd0) || (cfg_k > 16'd3) || (cfg_k == 16'd0) ||
                   (cfg_cin == 16'd0) || (cfg_out_w == 16'd0) || (cfg_out_h == 16'd0) ||
                   (cfg_cout == 16'd0) ||
                   ((cfg_stride != 16'd1) && (cfg_stride != 16'd2));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= ST_IDLE;
            pc       <= 4'd0;
            mac_cnt  <= 16'd0;
            st_cnt   <= 16'd0;
            loop_cnt <= 16'd0;
            busy_q   <= 1'b0;
            cyc_q    <= 32'd0;
            done_q   <= 1'b0;
            err_q    <= 1'b0;
            acc_ld   <= 1'b0;
            rq_en    <= 1'b0;
        end else begin
            acc_ld <= 1'b0;
            rq_en  <= 1'b0;
            done_q <= 1'b0;
            err_q  <= 1'b0;

            if (busy_q) cyc_q <= cyc_q + 32'd1;

            if (soft_rst || abort) begin
                st     <= ST_IDLE;
                busy_q <= 1'b0;
                pc     <= 4'd0;
            end else begin
                case (st)

                ST_IDLE: begin
                    if (start) begin
                        pc    <= 4'd0;
                        cyc_q <= 32'd0;
                        if (cfg_bad) begin
                            err_q  <= 1'b1;      // 配置非法：直接报错，不启动
                            busy_q <= 1'b0;
                            st     <= ST_IDLE;
                        end else begin
                            busy_q <= 1'b1;
                            st     <= ST_DISP;
                        end
                    end
                end

// ------------------------------------------------
// 译码：单拍指令在这里干完并推进 pc
                ST_DISP: begin
                    case (op)
                    OP_CONV_BEGIN: st <= ST_BEGIN;              // begin_ld 本拍有效
                    OP_ACC_CLR: begin
                        acc_ld <= 1'b1;                        // acc_in = cfg_bias
                        pc     <= pc + 4'd1;
                        st     <= ST_DISP;
                    end
                    OP_MAC: begin
                        mac_cnt <= mac_len;
                        st      <= ST_MAC;
                    end
                    OP_REQ: begin
                        rq_en <= 1'b1;
                        pc    <= pc + 4'd1;
                        st    <= ST_REQW;
                    end
                    OP_ST_OUT: begin
                        st_cnt <= 16'd0;
                        st     <= ST_ST;
                    end
                    OP_PIX_NEXT: begin
                        pc <= pc + 4'd1;
                        st <= ST_DISP;
                    end
                    OP_LOOP: begin
                        if (loop_cnt == 16'd0) loop_cnt <= loop_len;
                        st <= ST_LOOP;
                    end
                    OP_END, OP_NOP: st <= ST_END;
                    default:        st <= ST_END;   // 未知指令当 END 处理，不锁死
                    endcase
                end

// CONV_BEGIN：第 1 拍把描述符装进地址生成器
                ST_BEGIN: st <= ST_BEGIN2;
// 第 2 拍再装层首像素基址（pb_first_q 用到了 row_bytes，要晚一拍才稳）
                ST_BEGIN2: begin
                    pc <= pc + 4'd1;
                    st <= ST_DISP;
                end

                ST_MAC: begin
                    if (mac_cnt <= 16'd1) begin
                        mac_cnt <= 16'd4;
                        st      <= ST_MACEND;
                    end else begin
                        mac_cnt <= mac_cnt - 16'd1;
                    end
                end

                ST_MACEND: begin
                    if (mac_cnt <= 16'd1) begin
                        pc <= pc + 4'd1;
                        st <= ST_DISP;
                    end else begin
                        mac_cnt <= mac_cnt - 16'd1;
                    end
                end

// ------------------------------------------------
// requant：en 之后 2 拍 y 才有效
                ST_REQW:  st <= ST_REQW2;
                ST_REQW2: st <= ST_DISP;

                ST_ST: begin
                    if (st_cnt + 16'd1 >= nwords) begin
                        pc <= pc + 4'd1;
                        st <= ST_DISP;
                    end else begin
                        st_cnt <= st_cnt + 16'd1;
                    end
                end

                ST_LOOP: begin
                    if (loop_cnt <= 16'd1) begin
                        loop_cnt <= 16'd0;
                        pc       <= pc + 4'd1;
                    end else begin
                        loop_cnt <= loop_cnt - 16'd1;
                        pc       <= dst;
                    end
                    st <= ST_DISP;
                end

                ST_END: begin
                    done_q <= 1'b1;
                    busy_q <= 1'b0;
                    st     <= ST_IDLE;
                end

                default: st <= ST_IDLE;
                endcase
            end
        end
    end

endmodule
