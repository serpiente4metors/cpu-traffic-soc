// csr.v —— M 模式 CSR 最小集，含异常入口与中断应答
// mstatus / mie / mtvec / mepc / mcause / mcycle 等。

module csr (
    input  wire        clk,
    input  wire        rst_n,

// ---- E1 组合读 ----
    input  wire [11:0] raddr,
    output reg  [31:0] rdata,
    output reg         rexist,        // 该 CSR 是否存在（不存在 → 非法指令）

// ---- WB 写 ----
    input  wire        wen,
    input  wire [11:0] waddr,
    input  wire [31:0] wdata,

// ---- 退休计数 ----
    input  wire [1:0]  retire,

// ---- 陷阱 / 返回（WB 拍）----
    input  wire        trap_en,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_tval,
    input  wire        mret_en,

// ---- 中断源（电平）----
    input  wire        irq_ext,        // → mip.MEIP
    input  wire        irq_timer,      // → mip.MTIP

// ---- 输出 ----
    output wire [31:0] mepc_o,
    output wire [31:0] mtvec_o,
    output wire [31:0] mcause_o,
    output wire        global_ie,      // mstatus.MIE
    output wire        irq_pending     // |(mie & mip)
);

    reg [31:0] mstatus_q;
    reg [31:0] mtvec_q;
    reg [31:0] mepc_q;
    reg [31:0] mcause_q;
    reg [31:0] mtval_q;
    reg [31:0] mscratch_q;
    reg [31:0] mie_q;
    reg [31:0] mip_q;

    reg [63:0] cycle_q;
    reg [63:0] instret_q;

    localparam [11:0] CSR_MSTATUS  = 12'h300,
                      CSR_MISA     = 12'h301,
                      CSR_MIE      = 12'h304,
                      CSR_MTVEC    = 12'h305,
                      CSR_MSCRATCH = 12'h340,
                      CSR_MEPC     = 12'h341,
                      CSR_MCAUSE   = 12'h342,
                      CSR_MTVAL    = 12'h343,
                      CSR_MIP      = 12'h344,
                      CSR_MCYCLE   = 12'hB00,
                      CSR_MCYCLEH  = 12'hB80,
                      CSR_MINSTRET = 12'hB02,
                      CSR_MINSTRETH= 12'hB82,
                      CSR_CYCLE    = 12'hC00,
                      CSR_INSTRET  = 12'hC02,
                      CSR_MHARTID  = 12'hF14;

// mip 的 MEIP/MTIP 每拍由外部电平刷新（软件可读不可写这两位）
    always @* begin
        mip_q = 32'd0;
        mip_q[11] = irq_ext;
        mip_q[7]  = irq_timer;
    end

    assign mepc_o      = mepc_q;
    assign mtvec_o     = mtvec_q;
    assign mcause_o    = mcause_q;
    assign global_ie   = mstatus_q[3];
    assign irq_pending = |(mie_q & mip_q);

// ---------------- 组合读 ----------------
    always @* begin
        rdata  = 32'd0;
        rexist = 1'b1;
        case (raddr)
            CSR_MSTATUS : rdata = mstatus_q;
            CSR_MISA    : rdata = 32'h4000_1100;   // MXL=32, I + M
            CSR_MIE     : rdata = mie_q;
            CSR_MTVEC   : rdata = mtvec_q;
            CSR_MSCRATCH: rdata = mscratch_q;
            CSR_MEPC    : rdata = mepc_q;
            CSR_MCAUSE  : rdata = mcause_q;
            CSR_MTVAL   : rdata = mtval_q;
            CSR_MIP     : rdata = mip_q;
            CSR_MCYCLE  : rdata = cycle_q[31:0];
            CSR_MCYCLEH : rdata = cycle_q[63:32];
            CSR_MINSTRET: rdata = instret_q[31:0];
            CSR_MINSTRETH:rdata = instret_q[63:32];
            CSR_CYCLE   : rdata = cycle_q[31:0];
            CSR_INSTRET : rdata = instret_q[31:0];
            CSR_MHARTID : rdata = 32'd0;
            default     : begin rdata = 32'd0; rexist = 1'b0; end
        endcase
    end

// ---------------- 时序 ----------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mstatus_q  <= 32'd0;
            mtvec_q    <= 32'd0;
            mepc_q     <= 32'd0;
            mcause_q   <= 32'd0;
            mtval_q    <= 32'd0;
            mscratch_q <= 32'd0;
            mie_q      <= 32'd0;
            cycle_q    <= 64'd0;
            instret_q  <= 64'd0;
        end else begin
            cycle_q <= cycle_q + 64'd1;
            if (retire != 2'd0)
                instret_q <= instret_q + {62'd0, retire};

// ---- 普通 CSR 写 ----
            if (wen) begin
                case (waddr)
                    CSR_MSTATUS : mstatus_q  <= {wdata[31:4], wdata[3:0] & 4'b1000};
                    CSR_MIE     : mie_q      <= wdata & 32'h0000_0888;
                    CSR_MTVEC   : mtvec_q    <= {wdata[31:2], 2'b00};
                    CSR_MSCRATCH: mscratch_q <= wdata;
                    CSR_MEPC    : mepc_q     <= {wdata[31:2], 2'b00};
                    CSR_MCAUSE  : mcause_q   <= wdata;
                    CSR_MTVAL   : mtval_q    <= wdata;
                    CSR_MCYCLE  : cycle_q[31:0]  <= wdata;
                    CSR_MCYCLEH : cycle_q[63:32] <= wdata;
                    CSR_MINSTRET: instret_q[31:0]  <= wdata;
                    CSR_MINSTRETH:instret_q[63:32] <= wdata;
                    default: ;   // 只读 / 不存在的在译码阶段已被拦成非法指令
                endcase
            end

// ---- mret（优先级高于普通写）----
            if (mret_en) begin
                mstatus_q[3] <= mstatus_q[7];   // MIE  <= MPIE
                mstatus_q[7] <= 1'b1;           // MPIE <= 1
            end

// ---- 陷阱入口（优先级最高）----
            if (trap_en) begin
                mepc_q       <= {trap_pc[31:2], 2'b00};
                mcause_q     <= trap_cause;
                mtval_q      <= trap_tval;
                mstatus_q[7] <= mstatus_q[3];   // MPIE <= MIE
                mstatus_q[3] <= 1'b0;           // MIE  <= 0
                mstatus_q[12:11] <= 2'b11;      // MPP  <= M
            end
        end
    end

endmodule
