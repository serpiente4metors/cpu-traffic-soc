// uart_rx.v —— 8N1 接收器 + 256 字节 FIFO，位中点采样

module uart_rx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,        // 串口输入（空闲为高）
    input  wire       pop,       // 单拍：CPU 读走队首字节
    output wire [7:0] data,      // 当前队首字节（组合）
    output wire       valid,     // 1 = FIFO 非空
    output wire       frame_err, // 1 = 收到过帧错误（停止位为低）
    output wire       overflow   // 1 = FIFO 满时又收到字节（粘滞）
);

// DIV 四舍五入，至少为 1
    localparam integer DIV_RAW = (CLK_HZ + BAUD / 2) / BAUD;
    localparam integer DIV     = (DIV_RAW < 1) ? 1 : DIV_RAW;
    localparam integer HALF    = (DIV < 2) ? 1 : (DIV / 2);
    localparam integer CW      = (DIV < 2) ? 1 : $clog2(DIV);

    localparam [1:0] S_IDLE  = 2'd0,
                     S_START = 2'd1,
                     S_DATA  = 2'd2,
                     S_STOP  = 2'd3;

// ---- 输入同步：异步串口线打两拍 ----
    reg rx_meta, rx_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_meta <= 1'b1;
            rx_sync <= 1'b1;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
        end
    end

// ---- 接收状态机 ----
    reg [1:0]    st;
    reg [CW-1:0] cnt;
    reg [2:0]    biti;
    reg [7:0]    sh;
    reg          push_q;
    reg          frame_err_q;
    reg          overflow_q;

// count 在 FIFO 段使用，但 overflow 判定在状态机里也要用，所以提前声明
    reg  [8:0] count;
    wire full = (count == 9'd256);

    wire tick = (cnt == (DIV - 1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= S_IDLE;
            cnt         <= {CW{1'b0}};
            biti        <= 3'd0;
            sh          <= 8'd0;
            push_q      <= 1'b0;
            frame_err_q <= 1'b0;
            overflow_q  <= 1'b0;
        end else begin
            push_q <= 1'b0;

            case (st)
                S_IDLE: begin
                    cnt  <= {CW{1'b0}};
                    biti <= 3'd0;
                    if (!rx_sync) begin
                        st <= S_START;
                    end
                end

                S_START: begin
// 等半个位到起始位中点；仍为低才认作真起始位
                    if (cnt == (HALF - 1)) begin
                        cnt <= {CW{1'b0}};
                        if (!rx_sync) begin
                            st   <= S_DATA;
                            biti <= 3'd0;
                        end else begin
                            st <= S_IDLE;      // 毛刺
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                S_DATA: begin
                    if (tick) begin
                        cnt      <= {CW{1'b0}};
                        sh[biti] <= rx_sync;
                        if (biti == 3'd7) begin
                            st <= S_STOP;
                        end else begin
                            biti <= biti + 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: begin // S_STOP
                    if (tick) begin
                        cnt <= {CW{1'b0}};
                        st  <= S_IDLE;
                        if (rx_sync) begin
                            push_q <= 1'b1;
                        end else begin
                            frame_err_q <= 1'b1;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            endcase

// 粘滞错误只置位；软件可读 0x0C 的 bit9/bit10 查看
// （本版不清零，重新上电清）
            if (frame_err_q) begin
                frame_err_q <= 1'b1;
            end
            if (push_q && full && !pop) begin
                overflow_q <= 1'b1;
            end
        end
    end

// ---- 256 字节 FIFO ----
    reg  [7:0] fifo [0:255];
    reg  [7:0] wr_ptr, rd_ptr;

    wire empty = (count == 9'd0);

// full 且同时 pop 时允许写入（pop 先腾出一个位置）
    wire do_wr = push_q && (!full || pop);
    wire do_rd = pop && !empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 8'd0;
            rd_ptr <= 8'd0;
            count  <= 9'd0;
        end else begin
            if (do_wr) begin
                fifo[wr_ptr] <= sh;
                wr_ptr       <= wr_ptr + 1'b1;
            end
            if (do_rd) begin
                rd_ptr <= rd_ptr + 1'b1;
            end

            if (do_wr && !do_rd) begin
                count <= count + 1'b1;
            end else if (!do_wr && do_rd) begin
                count <= count - 1'b1;
            end
        end
    end

    assign data      = fifo[rd_ptr];
    assign valid     = !empty;
    assign frame_err = frame_err_q;
    assign overflow  = overflow_q;

endmodule
