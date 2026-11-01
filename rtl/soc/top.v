// top.v —— maxcpu 顶层：顺序双发 7 级流水线（RV32IM + Zicsr）
// IF1 → IF2 → ID → E1 → E2 → M → WB；slot1 走影子通路。

module top #(
    parameter MEM_FILE  = "program.mem",
    parameter ZERO_INIT = 1,
// 串口分频用：必须是【实际】送进 clk 的频率
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD   = 115200,
// NPU 权重文件（综合时相对 PDS 工作目录 pg200h/；仿真时可覆盖）
    parameter WGT_FILE0 = "../sw/npu/wgt_bank0.hex",
    parameter WGT_FILE1 = "../sw/npu/wgt_bank1.hex",
    parameter WGT_FILE2 = "../sw/npu/wgt_bank2.hex",
    parameter WGT_FILE3 = "../sw/npu/wgt_bank3.hex",
    parameter integer IC_SET_LOG = 6
) (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        ext_int,      // 外部中断（→ mip.MEIP, cause 11）
    input  wire        timer_int,    // 定时器中断（→ mip.MTIP, cause 7）

    output wire [7:0]  gpio_out,
    input  wire        uart_rx,      // 8N1 串口接收（0x1000_000C 读一字节）
    output wire        uart_tx,      // 8N1 串口发送（0x1000_0008 写一字节）
    output wire [31:0] tohost,       // 测试退出：写 0x1000_0000 的值

// ---- 仿真观测口（top_fpga 只连本地调试线网，不引出引脚）----
    output wire [31:0] dbg_pc,
    output wire        dbg_we,
    output wire [ 4:0] dbg_rd,
    output wire [31:0] dbg_wdata,
    output wire [31:0] dbg_instr,
    output wire [31:0] dbg_cycle,
    output wire [31:0] dbg_mcause,
    output wire [31:0] dbg_mepc,
    output wire [31:0] dbg_pc1,
    output wire        dbg_we1,
    output wire [ 4:0] dbg_rd1,
    output wire [31:0] dbg_wdata1,
    output wire [31:0] dbg_instr1
);

    reg         if2_valid_q;          // IF2
    reg  [31:0] if2_pc_q, if2_instr_q;
    reg         if2_ptk_q;
    reg  [31:0] if2_ptgt_q;
    reg  [31:0] if2_instr1_q;
    reg         if2_pair_q;

    reg         id_valid_q;           // ID
    reg  [31:0] id_pc_q, id_instr_q;
    reg         id_ptk_q;
    reg  [31:0] id_ptgt_q;
    reg  [31:0] id_instr1_q;
    reg         id_pair_q;

// ID -> E1
    reg         e_valid_q;
    reg  [31:0] e_pc_q, e_pc4_q, e_instr_q, e_imm_q;
    reg  [ 4:0] e_rs1_q, e_rs2_q, e_rd_q;
    reg  [ 3:0] e_alu_q;
    reg         e_a_pc_q, e_b_imm_q, e_we_q;
    reg         e_load_q, e_store_q, e_uns_q;
    reg  [ 1:0] e_size_q, e_jump_q;
    reg  [ 2:0] e_br_q, e_f3_q;
    reg         e_is_mul_q, e_is_div_q;
    reg         e_illegal_q;
    reg         e_is_csr_q, e_is_ecall_q, e_is_ebreak_q, e_is_mret_q;
    reg         e_ptk_q;              // 本条指令的预测方向
    reg  [31:0] e_ptgt_q;             // 本条指令的预测目标

// E1 -> E2
    reg         e2_valid_q;
    reg  [31:0] e2_pc_q, e2_pc4_q, e2_instr_q, e2_alu_q, e2_addr_q, e2_stdata_q, e2_npc_q;
    reg  [ 4:0] e2_rd_q;
    reg         e2_we_q, e2_load_q, e2_store_q, e2_uns_q;
    reg  [ 1:0] e2_size_q, e2_jump_q;
    reg         e2_redirect_q;        // E2：该条实际跳了（= e_redirect），误预测在 E2 组合判定
    reg         e2_isctrl_q;          // E2：该条是不是控制指令
    reg         e2_ptk_q;             // E2：该条被取指时给的预测方向
    reg  [31:0] e2_ptgt_q;            // E2：该条被取指时给的预测目标
    reg         e2_is_mul_q;
    reg         e2_exc_q;
    reg  [ 4:0] e2_cause_q;
    reg  [31:0] e2_tval_q;
    reg         e2_is_csr_q, e2_csr_wen_q;
    reg  [11:0] e2_csr_addr_q;
    reg  [31:0] e2_csr_wdata_q;
    reg         e2_mret_q;

// E2 -> M
    reg         m_valid_q;
    reg  [31:0] m_pc_q, m_pc4_q, m_instr_q, m_alu_q, m_addr_q, m_npc_q;
    reg  [ 4:0] m_rd_q;
    reg         m_we_q, m_load_q, m_uns_q;
    reg  [ 1:0] m_size_q, m_jump_q;
    reg         m_exc_q;
    reg  [ 4:0] m_cause_q;
    reg  [31:0] m_tval_q;
    reg         m_is_csr_q, m_csr_wen_q;
    reg  [11:0] m_csr_addr_q;
    reg  [31:0] m_csr_wdata_q;
    reg         m_mret_q;
    reg         m_mmio_q;
    reg  [31:0] m_mmio_rdata_q;

// M -> WB
    reg         wb_valid_q, wb_we_q;
    reg  [ 4:0] wb_rd_q;
    reg  [31:0] wb_data_q, wb_pc_q, wb_instr_q, wb_npc_q;
    reg         wb_exc_q;
    reg  [ 4:0] wb_cause_q;
    reg  [31:0] wb_tval_q;
    reg         wb_is_csr_q, wb_csr_wen_q;
    reg  [11:0] wb_csr_addr_q;
    reg  [31:0] wb_csr_wdata_q;
    reg         wb_mret_q;

    reg         e_valid1_q;
    reg  [ 3:0] e_alu1_q;
    reg  [31:0] e_imm1_q;
    reg         e_apc1_q, e_bimm1_q;
    reg  [ 4:0] e_rs1_1_q, e_rs2_1_q, e_rd_1_q;
    reg         e_we1_q;
    reg  [ 2:0] e_br1_q;              // P3-lite：lane1 条件分支类型（0=非分支）
    reg [31:0] e_instr1_q;           // 只为观测口（保留配对指令字）

    reg         e2_valid1_q;
    reg  [31:0] e2_val1_q, e2_instr1_q;
    reg  [ 4:0] e2_rd1_q;
    reg         e2_we1_q;
    reg         e2_redirect1_q;       // P3-lite：lane1 分支实际跳了
    reg  [31:0] e2_npc1_q;            // P3-lite：lane1 的正确下一条 PC
    reg         e2_isctrl1_q;         // P3-lite：lane1 这条是不是控制指令
    reg         e_load1_q, e_store1_q, e_uns1_q;
    reg  [ 1:0] e_size1_q;
    reg         e2_load1_q, e2_store1_q, e2_uns1_q;
    reg  [ 1:0] e2_size1_q;
    reg  [31:0] e2_addr1_q, e2_stdata1_q;
    reg         m_load1_q, m_uns1_q;
    reg  [ 1:0] m_size1_q;
    reg  [31:0] m_addr1_q;

    reg         m_valid1_q;
    reg  [31:0] m_val1_q, m_instr1_q;
    reg  [ 4:0] m_rd1_q;
    reg         m_we1_q;

    reg         wb_valid1_q;
    reg  [31:0] wb_val1_q;
    reg  [ 4:0] wb_rd1_q;
    reg         wb_we1_q;
// lane1 的 PC 不用单独寄存：成对时它恒等于 lane0 的 PC + 4
    reg  [31:0] wb_instr1_q;

    wire [63:0] i_rdata;              // A 口：取指，一次一行
    wire [31:0] d_rdata;              // B 口：数据，已选好半字（S10）
    wire [63:0] d_wdata;
    wire [ 7:0] d_be;
    wire        d_we;
    wire [31:0] d_addr /* synthesis syn_maxfan = 4 */;

    wire        load_use;             // 前向声明（存储器 i_ce 要用）
    wire        div_stall;
    wire        csr_stall;
    wire        redirect;             // 前向声明：E1 误预测在 E2 生效（赋值在下方）
    wire        trap_redirect;        // 前向声明：WB 的陷阱/mret/中断（赋值在下方）
    wire        rf_we1;              // 前向声明：lane1 的写使能（regfile 例化处就要用）

    wire [31:0] ic_mem_addr;          // I-Cache 送主存的读地址（必须显式声明 32 位）

//   这几个必须在 MMIO 段之前声明好，赋值在下面的 E2 段。
    wire        e2_mem1;
    wire [ 7:0] e2_wmask1;
    wire [31:0] e2_maddr, e2_mstdata;
    wire        e2_mmio_hit;

    dual_port_mem #(
        .MEM_FILE  (MEM_FILE),
        .ZERO_INIT (ZERO_INIT)
    ) u_mem (
        .clk     (clk),
// 取指数据由 I-Cache 逐行收走（行内 8 个 64 位字），i_ce 常开即可
        .i_ce    (1'b1),
        .i_addr  (ic_mem_addr),
        .i_rdata (i_rdata),
        .d_addr  (d_addr),
        .d_wdata (d_wdata),
        .d_be    (d_be),
        .d_we    (d_we),
        .d_rdata (d_rdata)
    );

    reg [31:0] tohost_q;
    reg [ 7:0] gpio_q;
    wire       uart_busy_q;
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;
    wire       uart_rx_ferr;
    wire       uart_rx_ovf;
    wire       uart_rx_pop;

    wire       e2_wr_any = e2_mem1 ? (e2_valid1_q && e2_store1_q && !e2_exc_q)
                                   : (e2_valid_q  && e2_store_q && !e2_exc_q);
    wire       mmio_wr = e2_wr_any && e2_mmio_hit && !div_stall;

    wire uart_wr = mmio_wr && (e2_maddr[7:0] == 8'h08);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tohost_q <= 32'd0;
            gpio_q   <= 8'd0;
        end else if (mmio_wr) begin
            if (e2_maddr[7:0] == 8'h00) tohost_q <= e2_mstdata;
            if (e2_maddr[7:0] == 8'h04) gpio_q   <= e2_mstdata[7:0];
        end
    end

    uart_tx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart_tx (
        .clk   (clk),
        .rst_n (rst_n),
        .wdata (e2_mstdata[7:0]),
        .wr    (uart_wr),
        .busy  (uart_busy_q),
        .tx    (uart_tx)
    );

// 读 0x0C 产生一个单拍 pop；div_stall 期间 E2 原地保持，不能重复弹。
// 注意：这里只认 load，store 到 0x0C 不会动 FIFO。
    wire e2_load_any = e2_mem1 ? e2_load1_q : (e2_valid_q && e2_load_q);
    assign uart_rx_pop = e2_mmio_hit && e2_load_any &&
                         (e2_maddr[7:0] == 8'h0C) && !div_stall;

    uart_rx #(
        .CLK_HZ (CLK_HZ),
        .BAUD   (BAUD)
    ) u_uart_rx (
        .clk       (clk),
        .rst_n     (rst_n),
        .rx        (uart_rx),
        .pop       (uart_rx_pop),
        .data      (uart_rx_data),
        .valid     (uart_rx_valid),
        .frame_err (uart_rx_ferr),
        .overflow  (uart_rx_ovf)
    );

    wire       npu_sel = |e2_maddr[7:4];
    wire       npu_wr  = mmio_wr && npu_sel;
    wire [31:0] npu_rdata;

    wire        npu_start, npu_soft_rst, npu_abort, npu_irq;
    wire        npu_busy_eng;      // NPU 占用中（给访存防呆用）
    wire        npu_mem_violation; // busy 期间 CPU 访存 → 置 STATUS.ERROR
    wire [31:0] npu_irq_en, npu_img_base, npu_wgt_base, npu_out_base;

    wire [15:0] npu_img_w, npu_img_h, npu_cin, npu_cout, npu_k;
    wire [15:0] npu_stride, npu_pad, npu_out_w, npu_out_h;
    wire [ 4:0] npu_shift;
    wire [511:0] npu_mbank;
    wire [32*32-1:0] npu_bias;     // S4.1：32 lane × int32
    wire         npu_act;          // S4.1：ReLU 使能

// NPU 引擎 ↔ 主存 B 口
    wire        npu_mem_sel /* synthesis syn_maxfan = 8 */;       // 1 = 这一拍 B 口归 NPU
    wire [16:0] npu_mem_raddr, npu_mem_waddr;
    wire        npu_mem_we;
    wire [63:0] npu_mem_wdata;
    wire [ 7:0] npu_mem_wstrb;
    wire        npu_core_done, npu_core_err;
    wire [31:0] npu_core_cycle;
    wire [ 3:0] npu_core_state;
// npu_regs.busy_o = 引擎 busy_i 与软件 busy 标志的或；
// 其中引擎 busy_i 也用于驱动 top.v 的访存防呆。
    wire        npu_busy_eng_i;

    npu_regs u_npu_regs (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr           (npu_wr),
        .addr         (e2_maddr[7:0]),
        .wdata        (e2_mstdata),
        .rdata        (npu_rdata),
        .start_pulse  (npu_start),
        .soft_rst_pulse(npu_soft_rst),
        .abort_pulse  (npu_abort),
        .npu_irq      (npu_irq),
        .busy_o       (npu_busy_eng),
        .irq_en       (npu_irq_en),
        .img_base     (npu_img_base),
        .wgt_base     (npu_wgt_base),
        .out_base     (npu_out_base),
        .img_w        (npu_img_w),
        .img_h        (npu_img_h),
        .cin          (npu_cin),
        .cout         (npu_cout),
        .ker          (npu_k),
        .stride       (npu_stride),
        .pad          (npu_pad),
        .out_w        (npu_out_w),
        .out_h        (npu_out_h),
        .shift        (npu_shift),
        .mbank        (npu_mbank),
        .bias_flat    (npu_bias),
        .act          (npu_act),
        .busy_i       (npu_busy_eng_i),
        .done_set_i   (npu_core_done),
        .err_set_i    (npu_mem_violation | npu_core_err),
        .cycle_i      (npu_core_cycle),
        .state_i      (npu_core_state)
    );

    wire [31:0] mmio_rdata_w = (e2_maddr[7:0] == 8'h00) ? tohost_q :
                               (e2_maddr[7:0] == 8'h04) ? {24'd0, gpio_q} :
                               (e2_maddr[7:0] == 8'h08) ? {31'd0, uart_busy_q} :
                               (e2_maddr[7:0] == 8'h0C) ? {21'd0, uart_rx_ovf,
                                                          uart_rx_ferr, uart_rx_valid,
                                                          uart_rx_data} :
                               npu_sel                  ? npu_rdata :
                                                          32'd0;

    assign tohost   = tohost_q;
    assign gpio_out = gpio_q;

    wire [511:0] ic_line;
    wire [ 31:0] ic_pc;
    wire         ic_hit, ic_stall;
    wire         ic_prof_miss, ic_prof_hit;   // 性能计数口，FPGA 上不接
// 前向声明：成对判据（S5.3 起要看"预测跳/不跳"）比 bpu 例化更早出现
    wire         bpu_taken;
    wire [ 31:0] bpu_target;
    wire         bpu1_taken;      // P3-lite：slot1 条件分支的 BHT 方向

    wire         fetch_consume;   // 本拍是否真的把交付的指令收进 IF2（赋值见下方）
    wire [ 31:0] ic_req;          // 送进阵列的读地址（赋值见下方）

    icache #(
        .SET_LOG  (IC_SET_LOG)
    ) u_icache (
        .clk      (clk),
        .rst_n    (rst_n),
        .req_pc   (ic_req),
        .out_pc   (ic_pc),
        .line     (ic_line),
        .hit      (ic_hit),
        .stall    (ic_stall),
        .mem_addr (ic_mem_addr),
        .mem_data (i_rdata),
        .miss       (ic_prof_miss),
        .lookup_hit (ic_prof_hit)
    );

    reg [63:0] fetch_dword;
    always @* begin
        case (ic_pc[5:3])
            3'd0: fetch_dword = ic_line[ 63:  0];
            3'd1: fetch_dword = ic_line[127: 64];
            3'd2: fetch_dword = ic_line[191:128];
            3'd3: fetch_dword = ic_line[255:192];
            3'd4: fetch_dword = ic_line[319:256];
            3'd5: fetch_dword = ic_line[383:320];
            3'd6: fetch_dword = ic_line[447:384];
            default: fetch_dword = ic_line[511:448];
        endcase
    end

    reg [31:0] fetch_hi32;          // pc 所在双字的**下一个**双字的低 32 bit
    always @* begin
        case (ic_pc[5:3])
            3'd0: fetch_hi32 = ic_line[ 95: 64];
            3'd1: fetch_hi32 = ic_line[159:128];
            3'd2: fetch_hi32 = ic_line[223:192];
            3'd3: fetch_hi32 = ic_line[287:256];
            3'd4: fetch_hi32 = ic_line[351:320];
            3'd5: fetch_hi32 = ic_line[415:384];
            3'd6: fetch_hi32 = ic_line[479:448];
// 行尾：真值在下一行里，取不到。填 0（全零是非法指令，
// 万一判据漏挡也是 trap 而不是静默错执行）
            default: fetch_hi32 = 32'd0;
        endcase
    end
    function automatic alu1_legal(input [31:0] ins);
        reg [6:0] op; reg [2:0] f3; reg [6:0] f7;
        begin
            op = ins[6:0]; f3 = ins[14:12]; f7 = ins[31:25];
            alu1_legal =
                (op == 7'h13) ?
                    ((f3 == 3'd0) || (f3 == 3'd2) || (f3 == 3'd3) || (f3 == 3'd4) ||
                     (f3 == 3'd6) || (f3 == 3'd7) ||
                     ((f3 == 3'd1) && (f7 == 7'h00)) ||
                     ((f3 == 3'd5) && ((f7 == 7'h00) || (f7 == 7'h20)))) :
                (op == 7'h33) ?
                    ((f7 == 7'h00) || ((f7 == 7'h20) && (f3 == 3'd0))) :
                (op == 7'h37) || (op == 7'h17);          // LUI / AUIPC
        end
    endfunction

    function automatic slot0_legal(input [31:0] ins);
        reg [6:0] op; reg [2:0] f3; reg [6:0] f7;
        begin
            op = ins[6:0]; f3 = ins[14:12]; f7 = ins[31:25];
            slot0_legal =
// ALU 类：mul 允许（积在 m 级从 mul_y 出），div 不允许（会整机冻结）
                (op == 7'h33) ? !((f7 == 7'h01) && f3[2]) :
// S5.1：load 也允许当 slot0。只放合法 funct3，
//        非法编码（3/6/7）留给单发通路去报 trap
                (op == 7'h03) ? ((f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2) ||
                                 (f3 == 3'd4) || (f3 == 3'd5)) :
// S5.1：store 同理。store 不写寄存器，但可以当一对的老大
                (op == 7'h23) ? ((f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2)) :
                alu1_legal(ins);
        end
    endfunction

    function automatic slot0_legal_br(input [31:0] ins);
        reg [6:0] op; reg [2:0] f3;
        begin
            op = ins[6:0]; f3 = ins[14:12];
            slot0_legal_br = slot0_legal(ins) ||
                             ((op == 7'h63) &&
                              ((f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd4) ||
                               (f3 == 3'd5) || (f3 == 3'd6) || (f3 == 3'd7)));
        end
    endfunction

    wire [31:0] fetch_instr0 = ic_pc[2] ? fetch_dword[63:32] : fetch_dword[31:0];
    wire [31:0] fetch_instr1 = ic_pc[2] ? fetch_hi32        : fetch_dword[63:32];
    wire [31:0] fetch_instr  = fetch_instr0;

    wire f_writes_rd0 = !((fetch_instr0[6:0] == 7'h23) ||
                          (fetch_instr0[6:0] == 7'h63));
    wire [4:0] f_rd0   = f_writes_rd0 ? fetch_instr0[11:7] : 5'd0;
// 【S11】lane1 当前可以配 load；store 数据通路保留但配对判据暂不启用。
//   同时要求 slot0 不是访存，D 口只有一个，一对里最多一条访存指令。
    function automatic slot1_ldst_ok(input [31:0] ins);
        reg [6:0] op; reg [2:0] f3;
        begin
            op = ins[6:0]; f3 = ins[14:12];
            slot1_ldst_ok =
                (op == 7'h03) ? ((f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2) ||
                                 (f3 == 3'd4) || (f3 == 3'd5)) :
                (op == 7'h23) ? ((f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd2)) :
                                1'b0;
        end
    endfunction

// P3-lite：slot1 放条件分支。只放“BPU 预测不跳”的，取指仍走 pc+8，
//   不需要第二个 BTB 目标口；真跳了就在 E2 重定向。
    function automatic slot1_br_ok(input [31:0] ins);
        reg [2:0] f3;
        begin
            f3 = ins[14:12];
            slot1_br_ok = (ins[6:0] == 7'h63) &&
                          ((f3 == 3'd0) || (f3 == 3'd1) || (f3 == 3'd4) ||
                           (f3 == 3'd5) || (f3 == 3'd6) || (f3 == 3'd7));
        end
    endfunction

    wire slot0_is_mem = ((fetch_instr0[6:0] == 7'h03) || (fetch_instr0[6:0] == 7'h23));
    wire slot1_mem_ok = !slot0_is_mem &&
                        (fetch_instr1[6:0] == 7'h03) &&
                        slot1_ldst_ok(fetch_instr1);

    wire f_writes_rd1 = !((fetch_instr1[6:0] == 7'h23) ||
                          (fetch_instr1[6:0] == 7'h63));
    wire [4:0] f_rd1  = f_writes_rd1 ? fetch_instr1[11:7] : 5'd0;
    wire [4:0] f_rs1_1 = fetch_instr1[19:15];
    wire [4:0] f_rs2_1 = fetch_instr1[24:20];

// 调试开关：置 0 可以单独验证"管道加宽但不开双发"，用来隔离问题
    localparam PAIR_EN = 1'b1;

// 【S5.2】配对不再要求 pc[2]==0，只禁行尾跨越：
//   pc[5:3]==7 && pc[2]==1 → slot1 在下一行，本行取不到，必须禁。
    wire pair_line_ok = !(ic_pc[2] && (ic_pc[5:3] == 3'd7));

// 【S5.3】slot0 是条件分支时，预测跳就必须让位（取指会走目标，见上面说明）
    wire pair_slot0_br = (fetch_instr0[6:0] == 7'h63);
    wire pair_ctrl_ok  = !pair_slot0_br || !bpu_taken;

    wire slot1_br_pair_ok = slot1_br_ok(fetch_instr1) && !pair_slot0_br && !bpu1_taken;

    wire pair_ok_w =
        PAIR_EN && pair_line_ok && pair_ctrl_ok &&
        slot0_legal_br(fetch_instr0) &&
        (alu1_legal(fetch_instr1) || slot1_mem_ok || slot1_br_pair_ok) &&
// R3 无 RAW：slot1 不能读 slot0 这一拍要写的寄存器
        !((f_rd0 != 5'd0) && ((f_rd0 == f_rs1_1) || (f_rd0 == f_rs2_1))) &&
// R4 无 WAW：两个写口不能写同一个寄存器
        !((f_rd1 != 5'd0) && (f_rd1 == f_rd0));

    wire [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    imm_gen u_imm (
        .instr (id_instr_q),
        .imm_i (imm_i), .imm_s (imm_s), .imm_b (imm_b),
        .imm_u (imm_u), .imm_j (imm_j)
    );

    wire [ 3:0] d_alu_op;
    wire [31:0] d_imm;
    wire        d_a_pc, d_b_imm, d_reg_we;
    wire        d_load, d_store, d_uns;
    wire [ 1:0] d_size, d_jump;
    wire [ 2:0] d_br, d_f3;
    wire        d_illegal, d_is_mul, d_is_div;
    wire        d_is_csr, d_is_ecall, d_is_ebreak, d_is_mret;

    ctrl_unit u_ctrl (
        .instr    (id_instr_q),
        .imm_i    (imm_i), .imm_s (imm_s), .imm_b (imm_b),
        .imm_u    (imm_u), .imm_j (imm_j),
        .alu_op   (d_alu_op), .imm (d_imm),
        .a_pc     (d_a_pc),   .b_imm (d_b_imm),
        .reg_we   (d_reg_we),
        .is_load  (d_load),   .is_store (d_store),
        .size     (d_size),   .uns (d_uns),
        .br       (d_br),     .jump (d_jump),
        .is_mul   (d_is_mul), .is_div (d_is_div), .funct3 (d_f3),
        .is_csr   (d_is_csr), .is_ecall (d_is_ecall), .is_ebreak (d_is_ebreak),
        .is_mret  (d_is_mret),
        .illegal  (d_illegal)
    );

    wire [ 4:0] id_rs1 = id_instr_q[19:15];
    wire [ 4:0] id_rs2 = id_instr_q[24:20];
    wire [ 4:0] id_rd  = id_instr_q[11:7];

    wire [31:0] imm_i1, imm_s1, imm_b1, imm_u1, imm_j1;
    imm_gen u_imm1 (
        .instr (id_instr1_q),
        .imm_i (imm_i1), .imm_s (imm_s1), .imm_b (imm_b1),
        .imm_u (imm_u1), .imm_j (imm_j1)
    );

    wire [ 3:0] d_alu_op1;
    wire [31:0] d_imm1;
    wire        d_a_pc1, d_b_imm1, d_reg_we1;
    wire        d_load1, d_store1, d_uns1;
    wire [ 1:0] d_size1, d_jump1;
    wire [ 2:0] d_br1, d_f31;
    wire        d_illegal1, d_is_mul1, d_is_div1;
    wire        d_is_csr1, d_is_ecall1, d_is_ebreak1, d_is_mret1;

    ctrl_unit u_ctrl1 (
        .instr    (id_instr1_q),
        .imm_i    (imm_i1), .imm_s (imm_s1), .imm_b (imm_b1),
        .imm_u    (imm_u1), .imm_j (imm_j1),
        .alu_op   (d_alu_op1), .imm (d_imm1),
        .a_pc     (d_a_pc1),   .b_imm (d_b_imm1),
        .reg_we   (d_reg_we1),
        .is_load  (d_load1),   .is_store (d_store1),
        .size     (d_size1),   .uns (d_uns1),
        .br       (d_br1),     .jump (d_jump1),
        .is_mul   (d_is_mul1), .is_div (d_is_div1), .funct3 (d_f31),
        .is_csr   (d_is_csr1), .is_ecall (d_is_ecall1),
        .is_ebreak(d_is_ebreak1), .is_mret (d_is_mret1),
        .illegal  (d_illegal1)
    );

    wire [4:0] id_rs1_1 = id_instr1_q[19:15];
    wire [4:0] id_rs2_1 = id_instr1_q[24:20];
    wire [4:0] id_rd_1  = id_instr1_q[11:7];

    wire [31:0] rf_rdata1, rf_rdata2;
    wire [31:0] rf_rdata1_1, rf_rdata2_1;

    regfile u_rf (
        .clk    (clk),
// 两个写口：lane0（老）+ lane1（新）。R4 判据保证两者 rd 不同。
        .we     (wb_we_q),
        .waddr  (wb_rd_q),
        .wdata  (wb_data_q),
        .we2    (rf_we1),
        .waddr2 (wb_rd1_q),
        .wdata2 (wb_val1_q),
        .raddr1 (e_rs1_q),
        .rdata1 (rf_rdata1),
        .raddr2 (e_rs2_q),
        .rdata2 (rf_rdata2),
        .raddr1_2 (e_rs1_1_q),
        .rdata1_2 (rf_rdata1_1),
        .raddr2_2 (e_rs2_1_q),
        .rdata2_2 (rf_rdata2_1)
    );

    wire [11:0] csr_raddr = e_imm_q[11:0];
    wire [31:0] csr_rdata, csr_mcause;
    wire        csr_rexist;
    wire [31:0] csr_mepc, csr_mtvec;
    wire        csr_global_ie, csr_irq_pending;

    wire        trap_take = wb_valid_q && wb_exc_q;
    wire        mret_take = wb_valid_q && wb_mret_q;

    wire        int_wb     = wb_valid_q && !wb_exc_q && !wb_mret_q &&
                             csr_global_ie && csr_irq_pending && !div_stall;

    wire [31:0] int_cause  = ext_int ? 32'h8000_000B : 32'h8000_0007;

    wire        csr_trap_en    = trap_take || int_wb;
    wire [31:0] csr_trap_pc    = trap_take ? wb_pc_q : wb_npc_q;
    wire [31:0] csr_trap_cause = trap_take ? {27'd0, wb_cause_q} : int_cause;
    wire [31:0] csr_trap_tval  = trap_take ? wb_tval_q : 32'd0;

    wire        csr_wen = wb_valid_q && wb_csr_wen_q && !wb_exc_q;
    wire [1:0]  retire;
    assign retire = {wb_valid1_q, wb_valid_q};

    csr u_csr (
        .clk         (clk),
        .rst_n       (rst_n),
        .raddr       (csr_raddr),
        .rdata       (csr_rdata),
        .rexist      (csr_rexist),
        .wen         (csr_wen),
        .waddr       (wb_csr_addr_q),
        .wdata       (wb_csr_wdata_q),
        .retire      (retire),
        .trap_en     (csr_trap_en),
        .trap_pc     (csr_trap_pc),
        .trap_cause  (csr_trap_cause),
        .trap_tval   (csr_trap_tval),
        .mret_en     (mret_take),
        .irq_ext     (ext_int),
        .irq_timer   (timer_int),
        .mepc_o      (csr_mepc),
        .mtvec_o     (csr_mtvec),
        .mcause_o    (csr_mcause),
        .global_ie   (csr_global_ie),
        .irq_pending (csr_irq_pending)
    );

    wire [31:0] m_addr_x = m_load1_q ? m_addr1_q : m_addr_q;
    wire [ 1:0] m_size_x = m_load1_q ? m_size1_q : m_size_q;
    wire        m_uns_x  = m_load1_q ? m_uns1_q  : m_uns_q;

    wire [ 1:0] m_off     = m_addr_x[1:0];   // 半字已在存储器里选好，这里只需字节
    wire [31:0] m_shifted = d_rdata >> {m_off, 3'b000};

    reg [31:0] m_load_aligned;
    always @* begin
        case (m_size_x)
            2'b00:   m_load_aligned = m_uns_x ? {24'd0, m_shifted[7:0]}
                                              : {{24{m_shifted[7]}},  m_shifted[7:0]};
            2'b01:   m_load_aligned = m_uns_x ? {16'd0, m_shifted[15:0]}
                                              : {{16{m_shifted[15]}}, m_shifted[15:0]};
            default: m_load_aligned = m_shifted[31:0];
        endcase
    end

    wire        e2_fwd_ok  = e2_valid_q && e2_we_q && !e2_load_q && (e2_rd_q != 5'd0);
    wire [31:0] e2_fwd_val = (|e2_jump_q) ? e2_pc4_q : e2_alu_q;

    wire        m_fwd_ok   = m_valid_q && m_we_q && (m_rd_q != 5'd0);
    wire [31:0] m_fwd_val  = m_load_q ? (m_mmio_q ? m_mmio_rdata_q : m_load_aligned)
                                     : ((|m_jump_q) ? m_pc4_q : m_alu_q);

    wire        wb_fwd_ok  = wb_we_q && (wb_rd_q != 5'd0);

    wire        e2_fwd1_ok = e2_valid1_q && e2_we1_q && (e2_rd1_q != 5'd0) && !e2_load1_q;
    wire        m_fwd1_ok  = m_valid1_q  && m_we1_q  && (m_rd1_q  != 5'd0);
    wire [31:0] m_fwd1_val = m_load1_q ? (m_mmio_q ? m_mmio_rdata_q : m_load_aligned)
                                       : m_val1_q;
    wire        wb_fwd1_ok = wb_we1_q    && (wb_rd1_q != 5'd0);

    wire [31:0] fwd_a =
        (e2_fwd1_ok && (e2_rd1_q == e_rs1_q)) ? e2_val1_q :
        (e2_fwd_ok  && (e2_rd_q  == e_rs1_q)) ? e2_fwd_val :
        (m_fwd1_ok  && (m_rd1_q  == e_rs1_q)) ? m_fwd1_val :
        (m_fwd_ok   && (m_rd_q   == e_rs1_q)) ? m_fwd_val  :
        (wb_fwd1_ok && (wb_rd1_q == e_rs1_q)) ? wb_val1_q :
        (wb_fwd_ok  && (wb_rd_q  == e_rs1_q)) ? wb_data_q  : rf_rdata1;

    wire [31:0] fwd_b =
        (e2_fwd1_ok && (e2_rd1_q == e_rs2_q)) ? e2_val1_q :
        (e2_fwd_ok  && (e2_rd_q  == e_rs2_q)) ? e2_fwd_val :
        (m_fwd1_ok  && (m_rd1_q  == e_rs2_q)) ? m_fwd1_val :
        (m_fwd_ok   && (m_rd_q   == e_rs2_q)) ? m_fwd_val  :
        (wb_fwd1_ok && (wb_rd1_q == e_rs2_q)) ? wb_val1_q :
        (wb_fwd_ok  && (wb_rd_q  == e_rs2_q)) ? wb_data_q  : rf_rdata2;

    wire [31:0] fwd_a1 =
        (e2_fwd1_ok && (e2_rd1_q == e_rs1_1_q)) ? e2_val1_q :
        (e2_fwd_ok  && (e2_rd_q  == e_rs1_1_q)) ? e2_fwd_val :
        (m_fwd1_ok  && (m_rd1_q  == e_rs1_1_q)) ? m_fwd1_val :
        (m_fwd_ok   && (m_rd_q   == e_rs1_1_q)) ? m_fwd_val  :
        (wb_fwd1_ok && (wb_rd1_q == e_rs1_1_q)) ? wb_val1_q :
        (wb_fwd_ok  && (wb_rd_q  == e_rs1_1_q)) ? wb_data_q : rf_rdata1_1;

    wire [31:0] fwd_b1 =
        (e2_fwd1_ok && (e2_rd1_q == e_rs2_1_q)) ? e2_val1_q :
        (e2_fwd_ok  && (e2_rd_q  == e_rs2_1_q)) ? e2_fwd_val :
        (m_fwd1_ok  && (m_rd1_q  == e_rs2_1_q)) ? m_fwd1_val :
        (m_fwd_ok   && (m_rd_q   == e_rs2_1_q)) ? m_fwd_val  :
        (wb_fwd1_ok && (wb_rd1_q == e_rs2_1_q)) ? wb_val1_q :
        (wb_fwd_ok  && (wb_rd_q  == e_rs2_1_q)) ? wb_data_q : rf_rdata2_1;

// lane1 的 PC 是 lane0 的 PC + 4（LUI / AUIPC 的 a_pc 要用到）
    wire [31:0] e_pc1 = e_pc_q + 32'd4;
    wire [31:0] opa1  = e_apc1_q ? e_pc1 : fwd_a1;
    wire [31:0] opb1  = e_bimm1_q ? e_imm1_q : fwd_b1;

    wire [31:0] alu_y1;
    alu u_alu1 (.alu_op(e_alu1_q), .a(opa1), .b(opb1), .y(alu_y1));

// lane1 的写使能。lane1 比同拍的 lane0 年轻，所以只要这一拍发生
// trap / mret / 中断重定向，它就不能提交（lane0 该写的照写）。
    assign rf_we1 = wb_we1_q && !trap_redirect;

    wire [31:0] opa = e_a_pc_q ? e_pc_q : fwd_a;
    wire [31:0] opb = e_b_imm_q ? e_imm_q : fwd_b;

    wire [31:0] alu_y;
    alu u_alu (.alu_op(e_alu_q), .a(opa), .b(opb), .y(alu_y));

    reg br_taken;
    always @* begin
        case (e_br_q)
            3'b001:  br_taken = (opa == opb);
            3'b010:  br_taken = (opa != opb);
            3'b011:  br_taken = ($signed(opa) <  $signed(opb));
            3'b100:  br_taken = ($signed(opa) >= $signed(opb));
            3'b101:  br_taken = (opa <  opb);
            3'b110:  br_taken = (opa >= opb);
            default: br_taken = 1'b0;
        endcase
    end

    wire        e_br_valid = (e_br_q != 3'd0);
    wire        e_redirect = (e_br_valid && br_taken) || (|e_jump_q);
    wire [31:0] e_target   = (e_jump_q == 2'd2) ? ((fwd_a + e_imm_q) & ~32'd1)
                                                : (e_pc_q + e_imm_q);
// 下一条体系结构 PC：中断/异常的 mepc 必须用它（错路预取的 pc 不可用）
    wire [31:0] e_npc      = e_redirect ? e_target : e_pc4_q;

    reg br_taken1;
    always @* begin
        case (e_br1_q)
            3'b001:  br_taken1 = (fwd_a1 == fwd_b1);
            3'b010:  br_taken1 = (fwd_a1 != fwd_b1);
            3'b011:  br_taken1 = ($signed(fwd_a1) <  $signed(fwd_b1));
            3'b100:  br_taken1 = ($signed(fwd_a1) >= $signed(fwd_b1));
            3'b101:  br_taken1 = (fwd_a1 <  fwd_b1);
            3'b110:  br_taken1 = (fwd_a1 >= fwd_b1);
            default: br_taken1 = 1'b0;
        endcase
    end

    wire        e_br1_valid  = (e_br1_q != 3'd0);
    wire        e_redirect1  = e_br1_valid && br_taken1;
    wire [31:0] e_target1    = e_pc1 + e_imm1_q;
    wire [31:0] e_npc1       = e_redirect1 ? e_target1 : (e_pc1 + 32'd4);
    wire        e_is_ctrl1_nv = e_br1_valid;

// ---------------- E1：乘 / 除 ----------------
    wire [31:0] mul_y;

    mul_unit u_mul (
        .clk  (clk),
        .rst_n(rst_n),
        .iss  (e_valid_q && e_is_mul_q),
        .f3   (e_f3_q),
        .a    (opa),
        .b    (opb),
        .y    (mul_y)
    );

    wire        div_busy, div_valid, div_start, div_ack;
    wire [31:0] div_result;

    assign div_ack   = e_valid_q && e_is_div_q && div_valid;
    assign div_start = e_valid_q && e_is_div_q && !div_busy && !div_valid &&
                       !redirect && !trap_redirect;

// ⚠ 冻结必须从 start 那一拍就开始（div_start 是组合的，busy 下一拍才起来）
    assign div_stall = div_start || div_busy;

    div_unit u_div (
        .clk      (clk),
        .rst_n    (rst_n),
        .start    (div_start),
        .ack      (div_ack),
        .a        (opa),
        .b        (opb),
        .is_signed(~e_f3_q[0]),
        .want_rem (e_f3_q[1]),
        .busy     (div_busy),
        .valid    (div_valid),
        .result   (div_result)
    );

// ---------------- E1：CSR 读改写 ----------------
    wire [31:0] csr_src  = e_f3_q[2] ? {27'd0, e_rs1_q} : fwd_a;
    wire [31:0] csr_new  = (e_f3_q[1:0] == 2'b01) ? csr_src :
                           (e_f3_q[1:0] == 2'b10) ? (csr_rdata |  csr_src) :
                                                    (csr_rdata & ~csr_src);
    wire        csr_do_w = (e_f3_q[1:0] == 2'b01) ? 1'b1 : (csr_src != 32'd0);

// ---------------- E1：异常检测 ----------------
    wire [1:0] ea = alu_y[1:0];
    wire mis_align = (e_load_q || e_store_q) ?
                       ((e_size_q == 2'b01) ? ea[0] :
                        (e_size_q == 2'b10) ? (|ea)  : 1'b0) : 1'b0;
    wire jmp_mis   = (e_jump_q == 2'd2) && e_target[1];
    wire csr_bad   = e_is_csr_q && !csr_rexist;

    wire e_exc = e_valid_q && (e_illegal_q || e_is_ecall_q || e_is_ebreak_q ||
                               csr_bad || mis_align || jmp_mis);
    wire [4:0] e_cause = e_illegal_q  ? 5'd2  :
                         e_is_ecall_q ? 5'd11 :
                         e_is_ebreak_q? 5'd3  :
                         csr_bad      ? 5'd2  :
                         e_load_q     ? 5'd4  :
                         e_store_q    ? 5'd6  : 5'd0;
// mtval 规则：非法指令给指令字、访存给地址、跳转非对齐给目标，
// ecall / ebreak 必须为 0（ISS 对拍暴露过一次）
    wire [31:0] e_tval = (e_illegal_q || csr_bad) ? e_instr_q :
                         (e_load_q || e_store_q)  ? alu_y    :
                         jmp_mis                  ? e_target : 32'd0;

// E1 级结果（进 e2_q）：CSR 读 > 除 > ALU；乘法的积在 E2 末才出（走 m_alu_q）
    wire [31:0] e_result = e_is_csr_q ? csr_rdata :
                           e_is_div_q ? div_result : alu_y;

    wire        e_is_ctrl_nv = e_br_valid || (|e_jump_q);   // 本条是不是控制指令（不含 valid）
    wire        e_is_ctrl    = e_valid_q && e_is_ctrl_nv;
// P3-lite：lane1 条件分支。配对时它一定是“预测不跳”，所以实际跳了就是误预测。
    wire        e_is_ctrl1   = e_valid1_q && e_is_ctrl1_nv;

    wire        e2_pred_ok = e2_ptk_q ? (e2_redirect_q && (e2_ptgt_q == e2_npc_q))
                                      : (!e2_redirect_q);
// 异常指令不在这里重定向：WB 的 trap 通路会整条清掉并跳到 mtvec
    wire        e2_mispred = e2_valid_q && e2_isctrl_q && !e2_exc_q && !e2_pred_ok;
    wire        e2_mispred1 = e2_valid1_q && e2_isctrl1_q && !e2_exc_q && e2_redirect1_q;

// BPU 更新口：一对里最多一条控制指令。slot1 分支配对时 slot0 一定不是控制指令。
    wire        u_sel1   = e_is_ctrl1 && !e_is_ctrl;
    wire [31:0] u_pc     = u_sel1 ? e_pc1       : e_pc_q;
    wire [31:0] u_instr  = u_sel1 ? e_instr1_q  : e_instr_q;
    wire        u_is_jmp = u_sel1 ? 1'b0        : (|e_jump_q);
    wire        u_taken  = u_sel1 ? e_redirect1 : e_redirect;
    wire [31:0] u_target = u_sel1 ? e_target1   : e_target;

    bpu u_bpu (
        .clk      (clk),
        .rst_n    (rst_n),
// IF1：预测查询 + 推测 push/pop（用本拍被消费的地址和指令字）
        .q_pc     (ic_pc),
        .q_instr  (fetch_instr),
        .q_en     (fetch_consume),
        .q_taken  (bpu_taken),
        .q_target (bpu_target),
// IF1：slot1 方向（只读 BHT；只用于决定“这条分支能不能进配对”）
        .q2_pc    (ic_pc + 32'd4),
        .q2_taken (bpu1_taken),
        .u_en     ((e_is_ctrl || e_is_ctrl1) && !redirect && !trap_redirect),
        .u_pc     (u_pc),
        .u_instr  (u_instr),
        .u_is_jmp (u_is_jmp),
        .u_taken  (u_taken),
        .u_target (u_target),
        .squash   (redirect || trap_redirect)
    );

    wire [7:0] e2_wmask = (e2_size_q == 2'b00) ? 8'h01 :
                          (e2_size_q == 2'b01) ? 8'h03 : 8'h0F;

    assign e2_wmask1 = (e2_size1_q == 2'b00) ? 8'h01 :
                       (e2_size1_q == 2'b01) ? 8'h03 : 8'h0F;
    assign e2_mem1   = e2_valid1_q && (e2_load1_q || e2_store1_q);

    assign e2_maddr   = e2_mem1 ? e2_addr1_q   : e2_addr_q;
    assign e2_mstdata = e2_mem1 ? e2_stdata1_q : e2_stdata_q;

// MMIO 只对访存指令有意义，用"本拍那个访存地址"判断
    wire e2_mem_any = e2_mem1 || (e2_valid_q && (e2_load_q || e2_store_q));
    assign e2_mmio_hit = e2_mem_any && (e2_maddr[31:8] == 24'h10_0000);

    wire [16:0] npu_win_off  = e2_maddr[16:0];
    wire        npu_win_hit  = e2_mem_any && (e2_maddr[31:17] == 15'h1000);

    npu_core #(
        .WGT_AW   (10),
        .WGT_FILE0 (WGT_FILE0),
        .WGT_FILE1 (WGT_FILE1),
        .WGT_FILE2 (WGT_FILE2),
        .WGT_FILE3 (WGT_FILE3)
    ) u_npu_core (
        .clk          (clk),
        .rst_n        (rst_n),
        .start        (npu_start),
        .soft_rst     (npu_soft_rst),
        .abort        (npu_abort),
        .busy         (npu_busy_eng_i),
        .done_pulse   (npu_core_done),
        .err_pulse    (npu_core_err),
        .state_o      (npu_core_state),
        .cycle_o      (npu_core_cycle),
        .cfg_img_base (npu_img_base[16:0]),
        .cfg_out_base (npu_out_base[16:0]),
        .cfg_wgt_base (npu_wgt_base[15:0]),
        .cfg_img_w    (npu_img_w),
        .cfg_img_h    (npu_img_h),
        .cfg_cin      (npu_cin),
        .cfg_cout     (npu_cout),
        .cfg_k        (npu_k),
        .cfg_stride   (npu_stride),
        .cfg_pad      (npu_pad),
        .cfg_out_w    (npu_out_w),
        .cfg_out_h    (npu_out_h),
        .cfg_shift    (npu_shift),
        .cfg_mbank    (npu_mbank),
        .cfg_bias     (npu_bias),
        .cfg_act      (npu_act),
        .mem_use      (npu_mem_sel),
        .mem_raddr    (npu_mem_raddr),
        .mem_rdata    (d_rdata),
        .mem_we       (npu_mem_we),
        .mem_waddr    (npu_mem_waddr),
        .mem_wdata    (npu_mem_wdata),
        .mem_wstrb    (npu_mem_wstrb)
    );

    wire [16:0] npu_b_off  = npu_mem_we ? npu_mem_waddr : npu_mem_raddr;
    wire [31:0] npu_b_addr = {15'd0, npu_b_off} + 32'h0001_0000;

    assign d_addr  = npu_mem_sel ? npu_b_addr :
                     npu_win_hit ? ({15'd0, npu_win_off} + 32'h0001_0000) : e2_maddr;
    assign d_we    = npu_mem_sel ? npu_mem_we : (e2_wr_any && !e2_mmio_hit);
    assign d_be    = npu_mem_sel ? npu_mem_wstrb :
                     ((e2_mem1 ? e2_wmask1 : e2_wmask) << e2_maddr[2:0]);
    assign d_wdata = npu_mem_sel ? npu_mem_wdata :
                     ({32'd0, e2_mstdata} << {e2_maddr[2:0], 3'b000});

    assign npu_mem_violation = npu_busy_eng && e2_mem_any && !e2_mmio_hit;

    wire lu0 = id_valid_q && e_valid_q && (e_load_q || e_is_mul_q) &&
               e_we_q && (e_rd_q != 5'd0) &&
               ((id_rs1 == e_rd_q) || (id_rs2 == e_rd_q));
    wire lu1 = id_valid_q && id_pair_q && e_valid_q && (e_load_q || e_is_mul_q) &&
               e_we_q && (e_rd_q != 5'd0) &&
               ((id_rs1_1 == e_rd_q) || (id_rs2_1 == e_rd_q));

    wire lu1a = id_valid_q && e_valid1_q && e_load1_q &&
                e_we1_q && (e_rd_1_q != 5'd0) &&
                ((id_rs1 == e_rd_1_q) || (id_rs2 == e_rd_1_q));
    wire lu1b = id_valid_q && id_pair_q && e_valid1_q && e_load1_q &&
                e_we1_q && (e_rd_1_q != 5'd0) &&
                ((id_rs1_1 == e_rd_1_q) || (id_rs2_1 == e_rd_1_q));

    assign load_use = lu0 || lu1 || lu1a || lu1b;

    wire id_is_sys = (id_instr_q[6:0] == 7'b1110_011);
    assign csr_stall = id_valid_q && id_is_sys &&
                       ((e_valid_q  && e_is_csr_q)  ||
                        (e2_valid_q && e2_is_csr_q) ||
                        (m_valid_q  && m_is_csr_q)  ||
                        (wb_valid_q && wb_is_csr_q));

    assign redirect = e2_mispred || e2_mispred1;
// lane0 的误预测优先（更老）；否则用 lane1 分支的真实目标
    wire [31:0] redirect_pc = e2_mispred ? e2_npc_q : e2_npc1_q;

    assign trap_redirect = trap_take || mret_take || int_wb;
    wire [31:0] trap_target   = trap_take ? csr_mtvec :
                                mret_take ? csr_mepc : csr_mtvec;

    assign fetch_consume = !trap_redirect && !div_stall && !redirect &&
                           !ic_stall && !load_use && !csr_stall;

    assign ic_req = redirect      ? redirect_pc :           // 误预测 → 真实的下一条
                    trap_redirect ? trap_target  :        // 陷阱/mret/中断（WB）
                    (fetch_consume ? (bpu_taken ? bpu_target
                                                : (ic_pc + (pair_ok_w ? 32'd8 : 32'd4)))
                                   : ic_pc);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            if2_valid_q <= 1'b0; if2_pc_q <= 32'd0; if2_instr_q <= 32'd0;
            if2_ptk_q   <= 1'b0; if2_ptgt_q <= 32'd0;
            id_valid_q  <= 1'b0; id_pc_q  <= 32'd0; id_instr_q  <= 32'd0;
            id_ptk_q    <= 1'b0; id_ptgt_q <= 32'd0;

            e_valid_q <= 1'b0; e_pc_q <= 32'd0; e_pc4_q <= 32'd0; e_instr_q <= 32'd0;
            e_imm_q <= 32'd0; e_rs1_q <= 5'd0; e_rs2_q <= 5'd0; e_rd_q <= 5'd0;
            e_alu_q <= 4'd0; e_a_pc_q <= 1'b0; e_b_imm_q <= 1'b0;
            e_we_q <= 1'b0; e_load_q <= 1'b0; e_store_q <= 1'b0; e_uns_q <= 1'b0;
            e_size_q <= 2'b10; e_jump_q <= 2'd0; e_br_q <= 3'd0; e_f3_q <= 3'd0;
            e_is_mul_q <= 1'b0; e_is_div_q <= 1'b0; e_illegal_q <= 1'b0;
            e_is_csr_q <= 1'b0; e_is_ecall_q <= 1'b0; e_is_ebreak_q <= 1'b0; e_is_mret_q <= 1'b0;
            e_ptk_q <= 1'b0; e_ptgt_q <= 32'd0;

            e2_valid_q <= 1'b0; e2_pc_q <= 32'd0; e2_pc4_q <= 32'd0; e2_instr_q <= 32'd0;
            e2_alu_q <= 32'd0; e2_addr_q <= 32'd0; e2_stdata_q <= 32'd0; e2_npc_q <= 32'd0;
            e2_rd_q <= 5'd0; e2_we_q <= 1'b0; e2_load_q <= 1'b0; e2_store_q <= 1'b0;
            e2_uns_q <= 1'b0; e2_size_q <= 2'b10; e2_jump_q <= 2'd0;
            e2_redirect_q <= 1'b0; e2_is_mul_q <= 1'b0;
            e2_isctrl_q <= 1'b0; e2_ptk_q <= 1'b0; e2_ptgt_q <= 32'd0;
            e2_exc_q <= 1'b0; e2_cause_q <= 5'd0; e2_tval_q <= 32'd0;
            e2_is_csr_q <= 1'b0; e2_csr_wen_q <= 1'b0;
            e2_csr_addr_q <= 12'd0; e2_csr_wdata_q <= 32'd0; e2_mret_q <= 1'b0;

            m_valid_q <= 1'b0; m_pc_q <= 32'd0; m_pc4_q <= 32'd0; m_instr_q <= 32'd0;
            m_alu_q <= 32'd0; m_addr_q <= 32'd0; m_npc_q <= 32'd0; m_rd_q <= 5'd0;
            m_we_q <= 1'b0; m_load_q <= 1'b0; m_uns_q <= 1'b0;
            m_size_q <= 2'b10; m_jump_q <= 2'd0;
            m_exc_q <= 1'b0; m_cause_q <= 5'd0; m_tval_q <= 32'd0;
            m_is_csr_q <= 1'b0; m_csr_wen_q <= 1'b0;
            m_csr_addr_q <= 12'd0; m_csr_wdata_q <= 32'd0; m_mret_q <= 1'b0;
            m_mmio_q <= 1'b0; m_mmio_rdata_q <= 32'd0;

            wb_valid_q <= 1'b0; wb_we_q <= 1'b0; wb_rd_q <= 5'd0;
            wb_data_q <= 32'd0; wb_pc_q <= 32'd0; wb_instr_q <= 32'd0; wb_npc_q <= 32'd0;
            wb_exc_q <= 1'b0; wb_cause_q <= 5'd0; wb_tval_q <= 32'd0;
            wb_is_csr_q <= 1'b0; wb_csr_wen_q <= 1'b0;
            wb_csr_addr_q <= 12'd0; wb_csr_wdata_q <= 32'd0; wb_mret_q <= 1'b0;

            e_valid1_q <= 1'b0; e_alu1_q <= 4'd0; e_imm1_q <= 32'd0;
            e_apc1_q <= 1'b0; e_bimm1_q <= 1'b0;
            e_rs1_1_q <= 5'd0; e_rs2_1_q <= 5'd0; e_rd_1_q <= 5'd0;
            e_we1_q <= 1'b0; e_instr1_q <= 32'd0;
            e_br1_q <= 3'd0;
            e2_valid1_q <= 1'b0; e2_val1_q <= 32'd0; e2_rd1_q <= 5'd0;
            e2_we1_q <= 1'b0; e2_instr1_q <= 32'd0;
            e2_redirect1_q <= 1'b0; e2_npc1_q <= 32'd0; e2_isctrl1_q <= 1'b0;
            m_valid1_q <= 1'b0; m_val1_q <= 32'd0; m_rd1_q <= 5'd0;
            m_we1_q <= 1'b0; m_instr1_q <= 32'd0;
            wb_valid1_q <= 1'b0; wb_val1_q <= 32'd0; wb_rd1_q <= 5'd0;
            wb_we1_q <= 1'b0; wb_instr1_q <= 32'd0;
            e_load1_q <= 1'b0; e_store1_q <= 1'b0; e_uns1_q <= 1'b0; e_size1_q <= 2'b10;
            e2_load1_q <= 1'b0; e2_store1_q <= 1'b0; e2_uns1_q <= 1'b0; e2_size1_q <= 2'b10;
            e2_addr1_q <= 32'd0; e2_stdata1_q <= 32'd0;
            m_load1_q <= 1'b0; m_uns1_q <= 1'b0; m_size1_q <= 2'b10; m_addr1_q <= 32'd0;

        end else if (trap_redirect) begin
            if2_valid_q  <= 1'b0;
            id_valid_q   <= 1'b0;
            e_valid_q    <= 1'b0;
            e2_valid_q   <= 1'b0;
            m_valid_q    <= 1'b0;
            wb_valid_q   <= 1'b0;
            wb_we_q      <= 1'b0;
            e_valid1_q   <= 1'b0;
            e2_valid1_q  <= 1'b0;
            m_valid1_q   <= 1'b0;
            wb_valid1_q  <= 1'b0;
            wb_we1_q     <= 1'b0;

        end else if (div_stall) begin
            wb_we_q <= 1'b0;
            wb_we1_q <= 1'b0;

        end else begin
// ---------------- 后端：无条件推进 ----------------
            e2_valid_q    <= redirect ? 1'b0 : e_valid_q;
            e2_pc_q       <= e_pc_q;
            e2_pc4_q      <= e_pc4_q;
            e2_instr_q    <= e_instr_q;
            e2_alu_q      <= e_result;
            e2_addr_q     <= alu_y;
            e2_stdata_q   <= fwd_b;
            e2_npc_q      <= e_npc;
            e2_rd_q       <= e_rd_q;
            e2_we_q       <= e_we_q;
            e2_load_q     <= e_load_q;
            e2_store_q    <= e_store_q;
            e2_uns_q      <= e_uns_q;
            e2_size_q     <= e_size_q;
            e2_addr1_q    <= alu_y1;
            e2_stdata1_q  <= fwd_b1;
            e2_load1_q    <= e_load1_q  && e_valid1_q;
            e2_store1_q   <= e_store1_q && e_valid1_q;
            e2_uns1_q     <= e_uns1_q;
            e2_size1_q    <= e_size1_q;
            e2_jump_q     <= e_jump_q;
            e2_redirect_q <= e_redirect;
            e2_isctrl_q   <= e_is_ctrl_nv;
            e2_ptk_q      <= e_ptk_q;
            e2_ptgt_q     <= e_ptgt_q;
            e2_is_mul_q   <= e_is_mul_q;
            e2_exc_q      <= e_exc;
            e2_cause_q    <= e_cause;
            e2_tval_q     <= e_tval;
            e2_is_csr_q   <= e_is_csr_q;
            e2_csr_wen_q  <= e_is_csr_q && csr_do_w;
            e2_csr_addr_q <= csr_raddr;
            e2_csr_wdata_q<= csr_new;
            e2_mret_q     <= e_is_mret_q;

// E2 -> M
            m_valid_q     <= e2_valid_q;
            m_pc_q        <= e2_pc_q;
            m_pc4_q       <= e2_pc4_q;
            m_instr_q     <= e2_instr_q;
            m_alu_q       <= e2_is_mul_q ? mul_y : e2_alu_q;
            m_addr_q      <= e2_addr_q;
            m_npc_q       <= e2_npc_q;
            m_rd_q        <= e2_rd_q;
            m_we_q        <= e2_we_q;
            m_load_q      <= e2_load_q;
            m_uns_q       <= e2_uns_q;
            m_size_q      <= e2_size_q;
            m_jump_q      <= e2_jump_q;
            m_exc_q       <= e2_exc_q;
            m_cause_q     <= e2_cause_q;
            m_tval_q      <= e2_tval_q;
            m_is_csr_q    <= e2_is_csr_q;
            m_csr_wen_q   <= e2_csr_wen_q && !e2_exc_q;
            m_csr_addr_q  <= e2_csr_addr_q;
            m_csr_wdata_q <= e2_csr_wdata_q;
            m_mret_q      <= e2_mret_q;
            m_mmio_q      <= e2_mmio_hit;
            m_mmio_rdata_q<= mmio_rdata_w;

            e2_valid1_q   <= redirect ? 1'b0 : e_valid1_q;   // 和 lane0 一样被 redirect 冲掉
            e2_val1_q     <= alu_y1;
            e2_rd1_q      <= e_rd_1_q;
            e2_we1_q      <= e_we1_q;
            e2_instr1_q   <= e_instr1_q;
            e2_redirect1_q<= e_redirect1;
            e2_npc1_q     <= e_npc1;
            e2_isctrl1_q  <= e_is_ctrl1_nv;

            m_valid1_q    <= redirect ? 1'b0 : e2_valid1_q;
            m_val1_q      <= e2_val1_q;
            m_rd1_q       <= e2_rd1_q;
            m_we1_q       <= e2_we1_q;
            m_instr1_q    <= e2_instr1_q;
            m_load1_q     <= e2_load1_q;
            m_uns1_q      <= e2_uns1_q;
            m_size1_q     <= e2_size1_q;
            m_addr1_q     <= e2_addr1_q;

// lane1 的写使能：lane0 在 M 级报异常时，lane1（更年轻）必须一起丢
            wb_valid1_q   <= m_valid1_q;
// store 不写寄存器：lane1 的 we1 在 E1 已由 d_reg_we1 给出（store=0），
// 这里再排除一次更稳妥。
            wb_we1_q      <= m_valid1_q && m_we1_q && !m_exc_q;   // store 的 we1 在 ctrl_unit 里已是 0
            wb_rd1_q      <= m_rd1_q;
            wb_val1_q     <= m_load1_q
                           ? (m_mmio_q ? m_mmio_rdata_q : m_load_aligned)
                           : m_val1_q;
            wb_instr1_q   <= m_instr1_q;

// M -> WB
            wb_valid_q    <= m_valid_q;
            wb_we_q       <= m_valid_q && m_we_q && !m_exc_q;
            wb_rd_q       <= m_rd_q;
            wb_data_q     <= m_load_q ? (m_mmio_q ? m_mmio_rdata_q : m_load_aligned)
                                      : ((|m_jump_q) ? m_pc4_q : m_alu_q);
            wb_pc_q       <= m_pc_q;
            wb_instr_q    <= m_instr_q;
            wb_npc_q      <= m_npc_q;
            wb_exc_q      <= m_exc_q;
            wb_cause_q    <= m_cause_q;
            wb_tval_q     <= m_tval_q;
            wb_is_csr_q   <= m_is_csr_q;
            wb_csr_wen_q  <= m_csr_wen_q;
            wb_csr_addr_q <= m_csr_addr_q;
            wb_csr_wdata_q<= m_csr_wdata_q;
            wb_mret_q     <= m_mret_q;

            if (redirect) begin
                if2_valid_q <= 1'b0;
                id_valid_q  <= 1'b0;
                e_valid_q   <= 1'b0;
                e_valid1_q  <= 1'b0;
            end else if (ic_stall) begin
// I-Cache 没命中 / 正在填行：这一拍不做捕获，地址下一拍仍指向同一条
                e_valid_q <= 1'b0;
                e_valid1_q <= 1'b0;
            end else if (load_use || csr_stall) begin
// 停前端 1 拍：给 e_q 打气泡（生产者本身必须继续前进）
                e_valid_q <= 1'b0;
                e_valid1_q <= 1'b0;
            end else begin
// IF2：地址、指令全部取自 icache 的同级寄存输出 → 原子配对
// 预测位也在这里一起捕获：它就是"取这条指令时给的那次预测"
                if2_valid_q <= 1'b1;
                if2_pc_q    <= ic_pc;
                if2_instr_q <= fetch_instr;
                if2_ptk_q   <= bpu_taken;
                if2_ptgt_q  <= bpu_target;
                if2_instr1_q<= fetch_instr1;      // S5
                if2_pair_q  <= pair_ok_w;         // S5

                id_valid_q  <= if2_valid_q;
                id_pc_q     <= if2_pc_q;
                id_instr_q  <= if2_instr_q;
                id_ptk_q    <= if2_ptk_q;
                id_ptgt_q   <= if2_ptgt_q;
                id_instr1_q <= if2_instr1_q;      // S5
                id_pair_q   <= if2_pair_q;        // S5

                e_valid_q   <= id_valid_q;
                e_pc_q      <= id_pc_q;
                e_pc4_q     <= id_pc_q + 32'd4;
                e_instr_q   <= id_instr_q;
                e_ptk_q     <= id_ptk_q;
                e_ptgt_q    <= id_ptgt_q;
                e_imm_q     <= d_imm;
                e_rs1_q     <= id_rs1;
                e_rs2_q     <= id_rs2;
                e_rd_q      <= id_rd;
                e_alu_q     <= d_alu_op;
                e_a_pc_q    <= d_a_pc;
                e_b_imm_q   <= d_b_imm;
                e_we_q      <= d_reg_we;
                e_load_q    <= d_load;
                e_store_q   <= d_store;
                e_size_q    <= d_size;
                e_uns_q     <= d_uns;
                e_load1_q   <= d_load1;
                e_store1_q  <= d_store1;
                e_size1_q   <= d_size1;
                e_uns1_q    <= d_uns1;
                e_br_q      <= d_br;
                e_jump_q    <= d_jump;
                e_is_mul_q  <= d_is_mul;
                e_is_div_q  <= d_is_div;
                e_f3_q      <= d_f3;
                e_illegal_q <= d_illegal;
                e_is_csr_q  <= d_is_csr;
                e_is_ecall_q<= d_is_ecall;
                e_is_ebreak_q<= d_is_ebreak;
                e_is_mret_q <= d_is_mret;

                e_valid1_q  <= id_valid_q && id_pair_q;
                e_alu1_q    <= d_alu_op1;
                e_imm1_q    <= d_imm1;
                e_apc1_q    <= d_a_pc1;
                e_bimm1_q   <= d_b_imm1;
                e_rs1_1_q   <= id_rs1_1;
                e_rs2_1_q   <= id_rs2_1;
                e_rd_1_q    <= id_rd_1;
                e_we1_q     <= d_reg_we1;
                e_br1_q     <= d_br1;
                e_instr1_q  <= id_instr1_q;
            end
        end
    end

    assign dbg_pc     = wb_pc_q;
    assign dbg_we     = wb_we_q && (wb_rd_q != 5'd0);
    assign dbg_rd     = wb_rd_q;
    assign dbg_wdata  = wb_data_q;
    assign dbg_instr  = wb_instr_q;
    assign dbg_mcause = csr_mcause;
    assign dbg_mepc   = csr_mepc;

    assign dbg_pc1    = wb_pc_q + 32'd4;
    assign dbg_we1    = rf_we1 && (wb_rd1_q != 5'd0);
    assign dbg_rd1    = wb_rd1_q;
    assign dbg_wdata1 = wb_val1_q;
    assign dbg_instr1 = wb_instr1_q;

    reg [31:0] cyc_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) cyc_q <= 32'd0;
        else        cyc_q <= cyc_q + 32'd1;
    end
    assign dbg_cycle = cyc_q;

endmodule
