// dual_port_mem.v —— 256 KB 统一存储器，真双口 64 bit（I/D 各占一口）
// 低 32 位 = lane0，高 32 位 = lane1；$readmemh 载入 program.mem。

module dual_port_mem #(
    parameter MEM_FILE  = "program.mem",
    parameter WORDS     = 32768,        // 32768 × 8B = 256KB
    parameter ZERO_INIT = 1             // 1 = 仿真（全清 0）；PDS 综合填 0
) (
    input  wire        clk,

// ---- A 口：指令取指（只读）----
    input  wire        i_ce,        // 读使能：0 时输出寄存器保持（停拍用）
    input  wire [31:0] i_addr,      // 字节地址（低 3 位忽略）
    output wire [63:0] i_rdata,     // 同步输出：晚 1 拍

// ---- B 口：数据访问（读写）----
    input  wire [31:0] d_addr,
    input  wire [63:0] d_wdata,
    input  wire [7:0]  d_be,        // 字节写使能（bit0 = 最低字节）
    input  wire        d_we,
    output wire [31:0] d_rdata      // 同步输出：晚 1 拍（已按 d_addr[2] 选好半字）
);

    wire [14:0] i_word = i_addr[17:3];
    wire [14:0] d_word = d_addr[17:3];

    reg [63:0] mem [0:WORDS-1];

    integer k;
    initial begin
        if (ZERO_INIT != 0) begin
            for (k = 0; k < WORDS; k = k + 1)
                mem[k] = 64'd0;
        end
    end

    initial begin
        $readmemh(MEM_FILE, mem);
    end

    reg [63:0] i_rdata_r, d_rdata_r;
    reg        d_hi_r;          // 与读数据同拍对齐的 d_addr[2]

    always @(posedge clk) begin
        if (i_ce) i_rdata_r <= mem[i_word];
        d_rdata_r <= mem[d_word];
        d_hi_r    <= d_addr[2];
    end

// ---- 字节使能写 ----
    always @(posedge clk) begin
        if (d_we) begin
            if (d_be[0]) mem[d_word][ 7: 0] <= d_wdata[ 7: 0];
            if (d_be[1]) mem[d_word][15: 8] <= d_wdata[15: 8];
            if (d_be[2]) mem[d_word][23:16] <= d_wdata[23:16];
            if (d_be[3]) mem[d_word][31:24] <= d_wdata[31:24];
            if (d_be[4]) mem[d_word][39:32] <= d_wdata[39:32];
            if (d_be[5]) mem[d_word][47:40] <= d_wdata[47:40];
            if (d_be[6]) mem[d_word][55:48] <= d_wdata[55:48];
            if (d_be[7]) mem[d_word][63:56] <= d_wdata[63:56];
        end
    end

    assign i_rdata = i_rdata_r;
// 读出 64 位后选半个字：到 ALU 那条长线由 64 根降到 32 根
    assign d_rdata = d_hi_r ? d_rdata_r[63:32] : d_rdata_r[31:0];

endmodule
