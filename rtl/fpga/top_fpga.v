// top_fpga.v —— 板级顶层：27 MHz 晶振 → PLL 94.5 MHz，上电复位与端口引出
// 板卡 盘古200H / PG2L200H-6FBB676；仅用于 PDS 综合，不参与仿真。

module top_fpga #(
    parameter USE_PLL        = 1,           // 1 = 走 PLL（pll_94_5，27→94.5 MHz）
    parameter PLL_CLK_FREQ   = 94_500_000,  // pll_94_5 的实际输出频率（串口分频+文档口径）
    parameter POR_CYCLES     = 1024,        // 必须 <= 2047（por_cnt 11 位）
    parameter ZERO_INIT      = 0,           // 综合必须 0（PDS 循环展开上限 2000）
    parameter SYS_CLK_HZ     = 27_000_000,
    parameter UART_BAUD      = 115200
) (
    input  wire       clk,        // D18
    input  wire       rst_n,      // C22
    input  wire       uart_rx,    // AC26
    output wire       uart_tx,    // AB26
    output wire [3:0] gpio_out,   // LED1~4
    input  wire [3:0] gpio_in     // KEY1~4
);

    wire clk_cpu;
    wire pll_lock;

    generate
        if (USE_PLL) begin : g_pll
            pll_94_5 u_cpu_pll (         // IP 名 pll_94_5（PDS IP Generator 生成，27x7/2 = 94.5 MHz）
                .clkin1  (clk),
                .clkout0 (clk_cpu),
                .lock    (pll_lock)
            );
        end else begin : g_nopll
            assign clk_cpu  = clk;
            assign pll_lock = 1'b1;
        end
    endgenerate

    reg [10:0] por_cnt;
    always @(posedge clk_cpu) begin
        if (por_cnt < POR_CYCLES[10:0])
            por_cnt <= por_cnt + 11'd1;
    end

    reg lock_sync0, lock_sync1;
    always @(posedge clk_cpu) begin
        lock_sync0 <= pll_lock;
        lock_sync1 <= lock_sync0;
    end

    wire rst_n_sys = lock_sync1 & (por_cnt >= POR_CYCLES[10:0]) & rst_n;

    wire [ 7:0] gpio_out_i;
    wire [31:0] tohost;
    wire [31:0] dbg_pc, dbg_wdata, dbg_instr, dbg_cycle, dbg_mcause, dbg_mepc;
    wire        dbg_we;
    wire [ 4:0] dbg_rd;

    localparam integer CORE_CLK_HZ = USE_PLL ? PLL_CLK_FREQ : SYS_CLK_HZ;

    top #(
        .MEM_FILE  ("../sw/program.mem"),
        .ZERO_INIT (ZERO_INIT),
        .CLK_HZ    (CORE_CLK_HZ),
        .BAUD      (UART_BAUD)
    ) u_top (
        .clk       (clk_cpu),
        .rst_n     (rst_n_sys),
        .ext_int   (1'b0),
        .timer_int (1'b0),
        .tohost    (tohost),
        .gpio_out  (gpio_out_i),
        .uart_rx   (uart_rx),
        .uart_tx   (uart_tx),
// 观测口不引出芯片，综合时被优化掉
        .dbg_pc    (dbg_pc),
        .dbg_we    (dbg_we),
        .dbg_rd    (dbg_rd),
        .dbg_wdata (dbg_wdata),
        .dbg_instr (dbg_instr),
        .dbg_cycle (dbg_cycle),
        .dbg_mcause(dbg_mcause),
        .dbg_mepc  (dbg_mepc)
    );

    assign gpio_out = gpio_out_i[3:0];

endmodule
