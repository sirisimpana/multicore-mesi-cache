// Convenience top-level wrappers for synthesis scripts and waveform viewers.
// The functional RTL remains in mesi_system.v; these modules only bind the
// cache associativity explicitly.

module mesi_system_dm (
    input clk,
    input reset,
    input [2:0] core_req_valid,
    input [2:0] core_req_write,
    input [23:0] core_req_addr,
    input [95:0] core_req_wdata,
    output [2:0] core_req_ready,
    output [2:0] core_resp_valid,
    output [95:0] core_resp_rdata,
    output busy,
    output [31:0] cycle_count,
    output [31:0] last_latency,
    output [31:0] completed_requests,
    output [31:0] total_latency
);
    mesi_system #(.WAYS(1)) u_mesi_system_dm (
        .clk(clk), .reset(reset),
        .core_req_valid(core_req_valid), .core_req_write(core_req_write),
        .core_req_addr(core_req_addr), .core_req_wdata(core_req_wdata),
        .core_req_ready(core_req_ready), .core_resp_valid(core_resp_valid),
        .core_resp_rdata(core_resp_rdata), .busy(busy),
        .cycle_count(cycle_count), .last_latency(last_latency),
        .completed_requests(completed_requests), .total_latency(total_latency)
    );
endmodule

module mesi_system_4way (
    input clk,
    input reset,
    input [2:0] core_req_valid,
    input [2:0] core_req_write,
    input [23:0] core_req_addr,
    input [95:0] core_req_wdata,
    output [2:0] core_req_ready,
    output [2:0] core_resp_valid,
    output [95:0] core_resp_rdata,
    output busy,
    output [31:0] cycle_count,
    output [31:0] last_latency,
    output [31:0] completed_requests,
    output [31:0] total_latency
);
    mesi_system #(.WAYS(4)) u_mesi_system_4way (
        .clk(clk), .reset(reset),
        .core_req_valid(core_req_valid), .core_req_write(core_req_write),
        .core_req_addr(core_req_addr), .core_req_wdata(core_req_wdata),
        .core_req_ready(core_req_ready), .core_resp_valid(core_resp_valid),
        .core_resp_rdata(core_resp_rdata), .busy(busy),
        .cycle_count(cycle_count), .last_latency(last_latency),
        .completed_requests(completed_requests), .total_latency(total_latency)
    );
endmodule
