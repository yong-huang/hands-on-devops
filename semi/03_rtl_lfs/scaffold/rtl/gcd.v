`timescale 1ns / 1ps
// gcd.v —— 欧几里得减法 GCD，valid/ready 双向握手（半导体 CI/CD 清单的 SUT）
// 接口约定见 docs/design-notes.md；单周期一步减法，最坏 ~2^W 周期收敛
module gcd #(
    parameter integer W = 16
) (
    input  wire         clk,
    input  wire         rst_n,       // 低有效同步释放
    // 请求握手：in_valid && in_ready 同拍即被接受
    input  wire         in_valid,
    input  wire [W-1:0] a_in,
    input  wire [W-1:0] b_in,
    output wire         in_ready,    // 组合输出：IDLE 态即可收
    // 结果握手：out_valid 拉起后 result 保持，等 out_ready 完成交接
    output reg          out_valid,
    output reg [W-1:0]  result,
    input  wire         out_ready
);
    localparam [1:0] S_IDLE = 2'd0,
                     S_RUN  = 2'd1,
                     S_DONE = 2'd2;

    reg [1:0]  state;
    reg [W-1:0] x, y;

    assign in_ready = (state == S_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            x         <= {W{1'b0}};
            y         <= {W{1'b0}};
            result    <= {W{1'b0}};
            out_valid <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    // 接受请求（本拍 in_valid 必须 >= 1 拍稳定）
                    if (in_valid) begin
                        x     <= a_in;
                        y     <= b_in;
                        state <= S_RUN;
                    end
                end
                S_RUN: begin
                    if (x == 0 || y == 0) begin
                        // gcd(a,0)=a，gcd(0,0)=0
                        result    <= (x > y) ? x : y;
                        out_valid <= 1'b1;
                        state     <= S_DONE;
                    end else if (x >= y) begin
                        x <= x - y;      // 辗转相减
                    end else begin
                        x <= y;          // 交换，保证大减小
                        y <= x;
                    end
                end
                S_DONE: begin
                    if (out_ready) begin
                        out_valid <= 1'b0;
                        state     <= S_IDLE;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
