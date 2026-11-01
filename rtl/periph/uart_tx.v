// uart_tx.v —— 8N1 发送器，一位占 DIV = CLK_HZ / BAUD 个时钟

module uart_tx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] wdata,   // 要发送的字节
    input  wire       wr,      // 单拍脉冲；busy=1 时为 1 会被丢弃
    output wire       busy,    // 1 = 本模块正在占用串口
    output wire       tx       // 串口输出线（空闲为高）
);

// DIV 四舍五入，至少为 1
    localparam integer DIV_RAW = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer DIV     = (DIV_RAW < 1) ? 1 : DIV_RAW;
    localparam integer CW      = (DIV < 2) ? 1 : $clog2(DIV);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

    reg [1:0]    st;
    reg [CW-1:0] cnt;      // 位内计数 0 .. DIV-1
    reg [2:0]    biti;     // 当前数据位 0..7
    reg [7:0]    sh;       // 发送移位寄存器（装载后不再移位，只按位取）
    reg          busy_q;

    wire tick = (cnt == (DIV - 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st     <= S_IDLE;
            cnt    <= {CW{1'b0}};
            biti   <= 3'd0;
            sh     <= 8'd0;
            busy_q <= 1'b0;
        end else begin
            case (st)
                S_IDLE: begin
                    cnt  <= {CW{1'b0}};
                    biti <= 3'd0;
                    if (wr) begin
                        sh     <= wdata;
                        busy_q <= 1'b1;
                        st     <= S_START;
                    end
                end

                S_START: begin
                    if (tick) begin
                        cnt  <= {CW{1'b0}};
                        biti <= 3'd0;
                        st   <= S_DATA;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (tick) begin
                        cnt <= {CW{1'b0}};
                        if (biti == 3'd7)
                            st   <= S_STOP;
                        else
                            biti <= biti + 1'b1;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: begin // S_STOP
                    if (tick) begin
                        cnt    <= {CW{1'b0}};
                        busy_q <= 1'b0;
                        st     <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            endcase
        end
    end

// tx 直接由寄存器化的 st / sh / biti 组合译出：
// 这三个量只在时钟沿变化，所以输出无毛刺，不需要再打一拍。
    assign tx = (st == S_IDLE)  ? 1'b1 :
                (st == S_START) ? 1'b0 :
                (st == S_DATA)  ? sh[biti] : 1'b1;

    assign busy = busy_q;

endmodule
