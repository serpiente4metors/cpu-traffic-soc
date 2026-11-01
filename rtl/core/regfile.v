// regfile.v —— 32×32 寄存器堆，4 读 2 写，异步读（分布式 RAM）

module regfile (
    input  wire        clk,

// 写口 1（lane0）
    input  wire        we,
    input  wire [ 4:0] waddr,
    input  wire [31:0] wdata,

// 写口 2（lane1，S5）
    input  wire        we2,
    input  wire [ 4:0] waddr2,
    input  wire [31:0] wdata2,

// 读口 1/2（lane0）
    input  wire [ 4:0] raddr1,
    output wire [31:0] rdata1,
    input  wire [ 4:0] raddr2,
    output wire [31:0] rdata2,

// 读口 1/2（lane1，S5）
    input  wire [ 4:0] raddr1_2,
    output wire [31:0] rdata1_2,
    input  wire [ 4:0] raddr2_2,
    output wire [31:0] rdata2_2
);

    reg [31:0] rf [1:31];

    integer i;
    initial begin
        for (i = 1; i < 32; i = i + 1)
            rf[i] = 32'd0;
    end

    always @(posedge clk) begin
        if (we && (waddr != 5'd0))
            rf[waddr] <= wdata;
        if (we2 && (waddr2 != 5'd0))
            rf[waddr2] <= wdata2;
    end

    assign rdata1   = (raddr1   == 5'd0) ? 32'd0 : rf[raddr1];
    assign rdata2   = (raddr2   == 5'd0) ? 32'd0 : rf[raddr2];
    assign rdata1_2 = (raddr1_2 == 5'd0) ? 32'd0 : rf[raddr1_2];
    assign rdata2_2 = (raddr2_2 == 5'd0) ? 32'd0 : rf[raddr2_2];

endmodule
