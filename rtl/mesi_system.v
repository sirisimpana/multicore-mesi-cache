// 3-core MESI cache-coherence system.
//   * 3 cores, one outstanding request on a serialized coherence bus
//   * one-word cache lines (32-bit words, 4-byte byte addresses)
//   * NUM_SETS sets and WAYS ways per core
//   * WAYS=1 gives a direct-mapped cache; WAYS=4 gives a 4-way cache
//   * MESI states are maintained per line and all evictions of M lines write
//     back to the on-chip backing memory
// The core-side request is held until core_req_ready is asserted.  The
// response is a one-cycle pulse on core_resp_valid.  A request is accepted
// only when no other request is in flight.

`timescale 1ns/1ps

module mesi_system #(
    parameter NUM_CORES = 3,
    parameter ADDR_W = 8,
    parameter DATA_W = 32,
    parameter NUM_SETS = 4,
    parameter WAYS = 1,
    parameter MEM_WORDS = 64,
    parameter MEM_LATENCY = 4,
    parameter SNOOP_LATENCY = 1
) (
    input                         clk,
    input                         reset,

    input  [NUM_CORES-1:0]        core_req_valid,
    input  [NUM_CORES-1:0]        core_req_write,
    input  [NUM_CORES*ADDR_W-1:0] core_req_addr,
    input  [NUM_CORES*DATA_W-1:0] core_req_wdata,
    output reg [NUM_CORES-1:0]    core_req_ready,

    output reg [NUM_CORES-1:0]    core_resp_valid,
    output reg [NUM_CORES*DATA_W-1:0] core_resp_rdata,

    output reg                    busy,
    output reg [31:0]             cycle_count,
    output reg [31:0]             last_latency,
    output reg [31:0]             completed_requests,
    output reg [31:0]             total_latency
);

    localparam INDEX_BITS = 2; // NUM_SETS is intentionally four in this project.
    localparam TAG_BITS = ADDR_W - INDEX_BITS - 2;
    localparam TOTAL_LINES = NUM_CORES * WAYS * NUM_SETS;
    localparam TOTAL_SETS = NUM_CORES * NUM_SETS;

    // MESI state encoding.
    localparam MESI_I = 2'b00;
    localparam MESI_S = 2'b01;
    localparam MESI_E = 2'b10;
    localparam MESI_M = 2'b11;

    localparam ST_IDLE  = 3'd0;
    localparam ST_LOOK  = 3'd1;
    localparam ST_SNOOP = 3'd2;
    localparam ST_MEM   = 3'd3;
    localparam ST_RESP  = 3'd4;

    reg [2:0] state;

    reg [TAG_BITS-1:0]    cache_tag   [0:TOTAL_LINES-1];
    reg [1:0]             cache_state [0:TOTAL_LINES-1];
    reg [DATA_W-1:0]      cache_data  [0:TOTAL_LINES-1];
    reg [1:0]             rr_way      [0:TOTAL_SETS-1];
    reg [DATA_W-1:0]      backing_mem  [0:MEM_WORDS-1];

    reg [1:0]              pending_core;
    reg                    pending_write;
    reg [ADDR_W-1:0]       pending_addr;
    reg [DATA_W-1:0]       pending_wdata;
    reg [31:0]             request_start_cycle;
    reg [31:0]             wait_count;
    reg [DATA_W-1:0]       response_data;
    reg [1:0]              arb_ptr;

    reg                    pending_miss;
    reg                    pending_hit;
    reg [1:0]              pending_hit_way;
    reg [1:0]              pending_victim_way;
    reg [DATA_W-1:0]       pending_fill_data;

    integer init_i;

    function integer line_index;
        input integer c;
        input integer w;
        input integer s;
        begin
            line_index = c * WAYS * NUM_SETS + w * NUM_SETS + s;
        end
    endfunction

    function integer set_index;
        input integer c;
        input integer s;
        begin
            set_index = c * NUM_SETS + s;
        end
    endfunction

    // Address fields.  Core addresses are byte addresses and all requests
    // are naturally aligned 32-bit word requests.
    wire [INDEX_BITS-1:0] pending_index = pending_addr[INDEX_BITS+1:2];
    wire [TAG_BITS-1:0]    pending_tag   = pending_addr[ADDR_W-1:INDEX_BITS+2];
    wire [ADDR_W-3:0]      pending_line  = pending_addr[ADDR_W-1:2];

    // Combinational lookup/snoop information for the current request.
    reg                    calc_hit;
    reg [1:0]              calc_hit_way;
    reg [1:0]              calc_victim_way;
    reg                    calc_other_found;
    reg                    calc_owner_found;
    reg                    calc_peer_data_found;
    reg [DATA_W-1:0]       calc_owner_data;
    reg [1:0]              calc_owner_state;
    integer calc_c;
    integer calc_w;
    integer calc_idx;
    integer calc_other_idx;
    integer calc_invalid_found;
    integer snoop_c;
    integer snoop_w;
    integer snoop_idx;

    always @(*) begin
        calc_hit = 1'b0;
        calc_hit_way = 2'd0;
        calc_victim_way = 2'd0;
        calc_other_found = 1'b0;
        calc_owner_found = 1'b0;
        calc_peer_data_found = 1'b0;
        calc_owner_data = {DATA_W{1'b0}};
        calc_owner_state = MESI_I;
        calc_invalid_found = 1'b0;

        // Find a hit in the requesting core.
        for (calc_w = 0; calc_w < WAYS; calc_w = calc_w + 1) begin
            calc_idx = line_index(pending_core, calc_w, pending_index);
            if (!calc_hit &&
                (cache_state[calc_idx] != MESI_I) &&
                (cache_tag[calc_idx] == pending_tag)) begin
                calc_hit = 1'b1;
                calc_hit_way = calc_w[1:0];
            end
        end

        // Prefer an invalid victim, otherwise use the per-set round-robin way.
        for (calc_w = 0; calc_w < WAYS; calc_w = calc_w + 1) begin
            calc_idx = line_index(pending_core, calc_w, pending_index);
            if (!calc_invalid_found && (cache_state[calc_idx] == MESI_I)) begin
                calc_victim_way = calc_w[1:0];
                calc_invalid_found = 1'b1;
            end
        end
        if (!calc_invalid_found)
            calc_victim_way = rr_way[set_index(pending_core, pending_index)];

        // Snoop all other cores for a copy of the requested line.
        for (calc_c = 0; calc_c < NUM_CORES; calc_c = calc_c + 1) begin
            if (calc_c != pending_core) begin
                for (calc_w = 0; calc_w < WAYS; calc_w = calc_w + 1) begin
                    calc_other_idx = line_index(calc_c, calc_w, pending_index);
                    if ((cache_state[calc_other_idx] != MESI_I) &&
                        (cache_tag[calc_other_idx] == pending_tag)) begin
                        calc_other_found = 1'b1;
                        // A shared line can be newer than backing memory if
                        // an M owner was downgraded to S.  Keep a data copy
                        // from any peer, then prefer an M/E owner if present.
                        if (!calc_peer_data_found) begin
                            calc_peer_data_found = 1'b1;
                            calc_owner_data = cache_data[calc_other_idx];
                        end
                        if (!calc_owner_found &&
                            ((cache_state[calc_other_idx] == MESI_M) ||
                             (cache_state[calc_other_idx] == MESI_E))) begin
                            calc_owner_found = 1'b1;
                            calc_owner_data = cache_data[calc_other_idx];
                            calc_owner_state = cache_state[calc_other_idx];
                        end
                    end
                end
            end
        end
    end

    // Round-robin arbitration is exposed on the ready bus so a requester can
    // hold valid until its turn.  Only one ready bit is asserted at a time.
    integer arb_scan;
    integer arb_candidate;
    integer arb_selected;
    reg     arb_found;
    always @(*) begin
        core_req_ready = {NUM_CORES{1'b0}};
        core_resp_valid = {NUM_CORES{1'b0}};
        core_resp_rdata = {(NUM_CORES*DATA_W){1'b0}};
        busy = (state != ST_IDLE);

        arb_found = 1'b0;
        arb_selected = 0;
        if (state == ST_IDLE) begin
            for (arb_scan = 0; arb_scan < NUM_CORES; arb_scan = arb_scan + 1) begin
                arb_candidate = (arb_ptr + arb_scan) % NUM_CORES;
                if (!arb_found && core_req_valid[arb_candidate]) begin
                    core_req_ready[arb_candidate] = 1'b1;
                    arb_selected = arb_candidate;
                    arb_found = 1'b1;
                end
            end
        end

        if (state == ST_RESP) begin
            core_resp_valid[pending_core] = 1'b1;
            core_resp_rdata[pending_core*DATA_W +: DATA_W] = response_data;
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= ST_IDLE;
            cycle_count <= 32'd0;
            last_latency <= 32'd0;
            completed_requests <= 32'd0;
            total_latency <= 32'd0;
            pending_core <= 2'd0;
            pending_write <= 1'b0;
            pending_addr <= {ADDR_W{1'b0}};
            pending_wdata <= {DATA_W{1'b0}};
            request_start_cycle <= 32'd0;
            wait_count <= 32'd0;
            response_data <= {DATA_W{1'b0}};
            arb_ptr <= 2'd0;
            pending_miss <= 1'b0;
            pending_hit <= 1'b0;
            pending_hit_way <= 2'd0;
            pending_victim_way <= 2'd0;
            pending_fill_data <= {DATA_W{1'b0}};

            for (init_i = 0; init_i < TOTAL_LINES; init_i = init_i + 1) begin
                cache_tag[init_i] <= {TAG_BITS{1'b0}};
                cache_state[init_i] <= MESI_I;
                cache_data[init_i] <= {DATA_W{1'b0}};
            end
            for (init_i = 0; init_i < TOTAL_SETS; init_i = init_i + 1)
                rr_way[init_i] <= 2'd0;
            for (init_i = 0; init_i < MEM_WORDS; init_i = init_i + 1)
                backing_mem[init_i] <= init_i;
        end else begin
            cycle_count <= cycle_count + 32'd1;

            case (state)
                ST_IDLE: begin
                    if (arb_found) begin
                        pending_core <= arb_selected[1:0];
                        pending_write <= core_req_write[arb_selected];
                        pending_addr <= core_req_addr[arb_selected*ADDR_W +: ADDR_W];
                        pending_wdata <= core_req_wdata[arb_selected*DATA_W +: DATA_W];
                        request_start_cycle <= cycle_count;
                        arb_ptr <= (arb_selected + 1) % NUM_CORES;
                        state <= ST_LOOK;
                    end
                end

                ST_LOOK: begin
                    pending_hit <= calc_hit;
                    pending_miss <= !calc_hit;
                    pending_hit_way <= calc_hit_way;
                    pending_victim_way <= calc_victim_way;

                    if (calc_hit) begin
                        // Read hits are local and complete immediately.
                        if (!pending_write) begin
                            response_data <= cache_data[line_index(pending_core,
                                                                  calc_hit_way,
                                                                  pending_index)];
                            state <= ST_RESP;
                        end else if ((cache_state[line_index(pending_core,
                                                              calc_hit_way,
                                                              pending_index)] == MESI_M) ||
                                     (cache_state[line_index(pending_core,
                                                              calc_hit_way,
                                                              pending_index)] == MESI_E)) begin
                            // E/M -> M is a local write hit.
                            cache_state[line_index(pending_core, calc_hit_way,
                                                   pending_index)] <= MESI_M;
                            cache_data[line_index(pending_core, calc_hit_way,
                                                  pending_index)] <= pending_wdata;
                            response_data <= pending_wdata;
                            state <= ST_RESP;
                        end else begin
                            // S -> M requires invalidating all peer copies.
                            wait_count <= SNOOP_LATENCY - 1;
                            state <= ST_SNOOP;
                        end
                    end else begin
                        // Write back an M victim before replacing it.
                        if (cache_state[line_index(pending_core, calc_victim_way,
                                                   pending_index)] == MESI_M) begin
                            backing_mem[{cache_tag[line_index(pending_core,
                                                              calc_victim_way,
                                                              pending_index)],
                                           pending_index}] <=
                                cache_data[line_index(pending_core, calc_victim_way,
                                                      pending_index)];
                        end

                        if (calc_peer_data_found)
                            pending_fill_data <= calc_owner_data;
                        else
                            pending_fill_data <= backing_mem[pending_line];

                        // An M owner is downgraded to S on a read snoop.  A
                        // write-back cache must make that value durable before
                        // the owner loses exclusive responsibility.
                        if (calc_owner_found && (calc_owner_state == MESI_M))
                            backing_mem[pending_line] <= calc_owner_data;

                        if (calc_other_found) begin
                            wait_count <= SNOOP_LATENCY - 1;
                            state <= ST_SNOOP;
                        end else begin
                            wait_count <= MEM_LATENCY - 1;
                            state <= ST_MEM;
                        end
                    end
                end

                ST_SNOOP: begin
                    if (wait_count != 0) begin
                        wait_count <= wait_count - 32'd1;
                    end else begin
                        // Peer transition for a read: M/E becomes S.  A write
                        // invalidates all peers.  The lookup is repeated here
                        // from the current arrays so no stale snoop response
                        // can be used.
                        for (snoop_c = 0; snoop_c < NUM_CORES; snoop_c = snoop_c + 1) begin
                            if (snoop_c != pending_core) begin
                                for (snoop_w = 0; snoop_w < WAYS; snoop_w = snoop_w + 1) begin
                                    snoop_idx = line_index(snoop_c, snoop_w, pending_index);
                                    if ((cache_state[snoop_idx] != MESI_I) &&
                                        (cache_tag[snoop_idx] == pending_tag)) begin
                                        if (pending_write)
                                            cache_state[snoop_idx] <= MESI_I;
                                        else
                                            cache_state[snoop_idx] <= MESI_S;
                                    end
                                end
                            end
                        end

                        if (pending_miss) begin
                            cache_tag[line_index(pending_core, pending_victim_way,
                                                 pending_index)] <= pending_tag;
                            cache_data[line_index(pending_core, pending_victim_way,
                                                  pending_index)] <= pending_fill_data;
                            if (pending_write) begin
                                cache_state[line_index(pending_core, pending_victim_way,
                                                       pending_index)] <= MESI_M;
                                cache_data[line_index(pending_core, pending_victim_way,
                                                      pending_index)] <= pending_wdata;
                                response_data <= pending_wdata;
                            end else begin
                                cache_state[line_index(pending_core, pending_victim_way,
                                                       pending_index)] <= MESI_S;
                                response_data <= pending_fill_data;
                            end
                            rr_way[set_index(pending_core, pending_index)] <=
                                (pending_victim_way + 1) % WAYS;
                        end else begin
                            cache_state[line_index(pending_core, pending_hit_way,
                                                   pending_index)] <= MESI_M;
                            cache_data[line_index(pending_core, pending_hit_way,
                                                  pending_index)] <= pending_wdata;
                            response_data <= pending_wdata;
                        end
                        state <= ST_RESP;
                    end
                end

                ST_MEM: begin
                    if (wait_count != 0) begin
                        wait_count <= wait_count - 32'd1;
                    end else begin
                        cache_tag[line_index(pending_core, pending_victim_way,
                                             pending_index)] <= pending_tag;
                        cache_data[line_index(pending_core, pending_victim_way,
                                              pending_index)] <= pending_fill_data;
                        if (pending_write) begin
                            cache_state[line_index(pending_core, pending_victim_way,
                                                   pending_index)] <= MESI_M;
                            cache_data[line_index(pending_core, pending_victim_way,
                                                  pending_index)] <= pending_wdata;
                            response_data <= pending_wdata;
                        end else begin
                            // No peer has a copy, so a clean read fill is E.
                            cache_state[line_index(pending_core, pending_victim_way,
                                                   pending_index)] <= MESI_E;
                            response_data <= pending_fill_data;
                        end
                        rr_way[set_index(pending_core, pending_index)] <=
                            (pending_victim_way + 1) % WAYS;
                        state <= ST_RESP;
                    end
                end

                ST_RESP: begin
                    last_latency <= cycle_count - request_start_cycle;
                    completed_requests <= completed_requests + 32'd1;
                    total_latency <= total_latency + (cycle_count - request_start_cycle);
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
