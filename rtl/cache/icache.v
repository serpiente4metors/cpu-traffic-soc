// icache.v —— 指令 Cache：64 组 × 2 路 × 64 B = 8 KB，同步读
// SET_LOG 只改组数，行大小固定 64 B。

module icache #(
    parameter integer SET_LOG = 6          // 组数 = 2^SET_LOG
) (
    input  wire         clk,
    input  wire         rst_n,

    input  wire [ 31:0] req_pc,      // IF1：本级发出的取指地址

    output wire [ 31:0] out_pc,      // IF2：与 line 精确配对的地址
    output wire [511:0] line,        // IF2：out_pc 所在的整行（64 B）
    output wire         hit,         // IF2：行有效且 tag 匹配
    output wire         stall,       // 前端必须停（缺失 / 填充中）

    output wire [ 31:0] mem_addr,    // 主存读口（复用 dual_port_mem 的 I 口）
    input  wire [ 63:0] mem_data,

    output wire         miss,        // 性能计数：填充起点（缺失）
    output wire         lookup_hit   // 性能计数：命中查询
);

// 所有宽度都由 SET_LOG 推出来，不要再硬编码 6/12/20 这些魔数
    localparam integer NSET = (1 << SET_LOG) - 1;   // 最大组号
    localparam integer TAGW = 26 - SET_LOG;         // tag 位宽（6 是行内偏移）
    localparam integer HIB  = 5 + SET_LOG;          // set 最高位（SET_LOG=6 → 11）

// 两路写成两套独立阵列：比 reg[511:0] data[0:1][0:63] 更好综合
    reg [511:0] data0 [0:NSET];
    reg [511:0] data1 [0:NSET];
    reg [TAGW-1:0] tag0 [0:NSET];
    reg [TAGW-1:0] tag1 [0:NSET];
    reg         vld0  [0:NSET];
    reg         vld1  [0:NSET];
    reg         repl  [0:NSET];

// 仿真初始化（同时是 RAM 的上电初值；综合时这段变成 BRAM 的 INIT 内容）
    integer i;
    initial begin
        for (i = 0; i <= NSET; i = i + 1) begin
            data0[i] = 512'd0;
            data1[i] = 512'd0;
            tag0[i]  = {TAGW{1'b0}};
            tag1[i]  = {TAGW{1'b0}};
            vld0[i]  = 1'b0;
            vld1[i]  = 1'b0;
            repl[i]  = 1'b0;
        end
    end

    wire [SET_LOG-1:0] rd_set = req_pc[HIB:6];

    reg [511:0] r_line0, r_line1;
    reg [TAGW-1:0] r_tag0, r_tag1;
    reg         r_vld0,  r_vld1;
    reg [ 31:0] r_pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_pc   <= 32'd0;
            r_vld0 <= 1'b0;
            r_vld1 <= 1'b0;
        end else begin
            r_line0 <= data0[rd_set];
            r_line1 <= data1[rd_set];
            r_tag0  <= tag0[rd_set];
            r_tag1  <= tag1[rd_set];
            r_vld0  <= vld0[rd_set];
            r_vld1  <= vld1[rd_set];
            r_pc    <= req_pc;
        end
    end

    assign out_pc = r_pc;

    wire hit0 = r_vld0 && (r_tag0 == r_pc[31:6+SET_LOG]);
    wire hit1 = r_vld1 && (r_tag1 == r_pc[31:6+SET_LOG]);

    assign hit  = hit0 | hit1;
    assign line = hit0 ? r_line0 : r_line1;

    localparam [1:0] S_IDLE = 2'd0,
                     S_FILL = 2'd1,
                     S_INST = 2'd2,
                     S_WAIT = 2'd3;   // 装完等一拍：让 r_tag/r_valid 追上再判命中

    reg [1:0]   st;
    reg [4:0]   fcnt;            // 0..8
    reg [25:0]  base;            // 行地址（pc[31:6]），填充期间冻结
    reg [SET_LOG-1:0] fl_set;
    reg         fl_way;
    reg [TAGW-1:0] fl_tag;
    reg [511:0] fill;

// 第 fcnt 次读的地址偏移；fcnt==8 时地址已无意义，钳到 56 免得回卷
    wire [2:0]  fword = (fcnt >= 5'd8) ? 3'd7 : fcnt[2:0];
    wire [31:0] fidx  = ({27'd0, fcnt} - 32'd1) << 6;   // 必须用 32 位算，否则 5 位乘法截断

// ---- 性能计数（纯观测，不影响任何逻辑）----
    assign miss       = (st == S_IDLE) && !hit;
    assign lookup_hit = (st == S_IDLE) &&  hit;

    assign stall    = (st != S_IDLE) || !hit;
    assign mem_addr = {base[25:0], 6'b000000} + {26'd0, fword, 3'b000};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= S_IDLE;
            fcnt   <= 5'd0;
            base   <= 26'd0;
            fl_set <= {SET_LOG{1'b0}};
            fl_way <= 1'b0;
            fl_tag <= {TAGW{1'b0}};
            fill   <= 512'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (!hit) begin
                        st     <= S_FILL;
                        fcnt   <= 5'd0;
                        base   <= r_pc[31:6];
                        fl_set <= r_pc[HIB:6];
                        fl_way <= repl[r_pc[HIB:6]];
                        fl_tag <= r_pc[31:6+SET_LOG];
                        fill   <= 512'd0;
                    end
                end
                S_FILL: begin
// 地址在第 k 拍发出，数据第 k+1 拍到 → 存进第 k 个字
                    if (fcnt >= 5'd1)
                        fill[fidx +: 64] <= mem_data;

                    if (fcnt == 5'd8)
                        st <= S_INST;
                    else
                        fcnt <= fcnt + 5'd1;
                end
                S_INST: begin
                    st <= S_WAIT;          // 阵列写入在下面那个"无复位"块里
                end
                S_WAIT: begin
// 刚装完这一拍 hit 还是旧值，直接回 S_IDLE 会被判成 miss 再填一次
                    st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end

    always @(posedge clk) begin
        if (st == S_INST) begin
            if (fl_way == 1'b0) begin
                vld0[fl_set] <= 1'b1;
                tag0[fl_set] <= fl_tag;
                data0[fl_set] <= fill;
            end else begin
                vld1[fl_set] <= 1'b1;
                tag1[fl_set] <= fl_tag;
                data1[fl_set] <= fill;
            end
            repl[fl_set] <= ~repl[fl_set];
        end
    end

endmodule
