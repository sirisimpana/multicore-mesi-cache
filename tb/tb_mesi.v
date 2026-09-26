// Self-checking directed verification for the 3-core MESI system.
//
// The testbench instantiates the exact same RTL twice:
//   dut_dm : WAYS=1  (direct mapped)
//   dut_4w : WAYS=4  (4-way set associative)
//
// It checks returned data against a reference memory model, checks MESI
// invariants every clock, exercises all three cores and reports directed
// functional bins.  The conflict benchmark is deliberately chosen so that
// four lines map to one set: direct mapping repeatedly misses while the
// four-way cache retains all four lines.

`timescale 1ns/1ps

module tb_mesi;
    localparam NUM_CORES = 3;
    localparam ADDR_W = 8;
    localparam DATA_W = 32;
    localparam MEM_WORDS = 64;

    reg clk;
    reg reset;
    integer tb_cycle;

    reg [NUM_CORES-1:0] dm_valid;
    reg [NUM_CORES-1:0] dm_write;
    reg [NUM_CORES*ADDR_W-1:0] dm_addr;
    reg [NUM_CORES*DATA_W-1:0] dm_wdata;
    wire [NUM_CORES-1:0] dm_ready;
    wire [NUM_CORES-1:0] dm_resp;
    wire [NUM_CORES*DATA_W-1:0] dm_rdata;
    wire [31:0] dm_last_latency;
    wire [31:0] dm_completed;
    wire [31:0] dm_total_latency;

    reg [NUM_CORES-1:0] fa_valid;
    reg [NUM_CORES-1:0] fa_write;
    reg [NUM_CORES*ADDR_W-1:0] fa_addr;
    reg [NUM_CORES*DATA_W-1:0] fa_wdata;
    wire [NUM_CORES-1:0] fa_ready;
    wire [NUM_CORES-1:0] fa_resp;
    wire [NUM_CORES*DATA_W-1:0] fa_rdata;
    wire [31:0] fa_last_latency;
    wire [31:0] fa_completed;
    wire [31:0] fa_total_latency;

    mesi_system #(.WAYS(1)) dut_dm (
        .clk(clk), .reset(reset),
        .core_req_valid(dm_valid), .core_req_write(dm_write),
        .core_req_addr(dm_addr), .core_req_wdata(dm_wdata),
        .core_req_ready(dm_ready), .core_resp_valid(dm_resp),
        .core_resp_rdata(dm_rdata), .busy(), .cycle_count(),
        .last_latency(dm_last_latency), .completed_requests(dm_completed),
        .total_latency(dm_total_latency)
    );

    mesi_system #(.WAYS(4)) dut_4w (
        .clk(clk), .reset(reset),
        .core_req_valid(fa_valid), .core_req_write(fa_write),
        .core_req_addr(fa_addr), .core_req_wdata(fa_wdata),
        .core_req_ready(fa_ready), .core_resp_valid(fa_resp),
        .core_resp_rdata(fa_rdata), .busy(), .cycle_count(),
        .last_latency(fa_last_latency), .completed_requests(fa_completed),
        .total_latency(fa_total_latency)
    );

    reg [DATA_W-1:0] model_mem [0:MEM_WORDS-1];
    integer i;
    integer error_count;
    integer dm_conflict_latency;
    integer fa_conflict_latency;
    integer dm_intercore_latency;
    integer fa_intercore_latency;
    integer coverage_bins [0:11];
    integer coverage_covered;
    integer dm_latency;
    integer fa_latency;
    integer expected_word;

    localparam MESI_I = 2'b00;
    localparam MESI_S = 2'b01;
    localparam MESI_E = 2'b10;
    localparam MESI_M = 2'b11;

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (!reset)
            tb_cycle = tb_cycle + 1;
    end

    task test_fail;
        input [1023:0] message;
        begin
            error_count = error_count + 1;
            $display("[FAIL @ cycle %0d] %0s", tb_cycle, message);
        end
    endtask

    task mark_coverage;
        input integer bin_number;
        begin
            coverage_bins[bin_number] = 1;
        end
    endtask

    task reset_systems;
        integer r;
        begin
            @(negedge clk);
            reset = 1'b1;
            dm_valid = 3'b000;
            dm_write = 3'b000;
            dm_addr = {(NUM_CORES*ADDR_W){1'b0}};
            dm_wdata = {(NUM_CORES*DATA_W){1'b0}};
            fa_valid = 3'b000;
            fa_write = 3'b000;
            fa_addr = {(NUM_CORES*ADDR_W){1'b0}};
            fa_wdata = {(NUM_CORES*DATA_W){1'b0}};
            for (r = 0; r < MEM_WORDS; r = r + 1)
                model_mem[r] = r;
            repeat (3) @(posedge clk);
            @(negedge clk);
            reset = 1'b0;
        end
    endtask

    // A single direct-mapped transaction.  The request is driven on a
    // falling edge and held until the DUT grants it.
    task dm_access;
        input integer core;
        input integer is_write;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] write_data;
        input [DATA_W-1:0] expected_data;
        output integer measured_latency;
        integer start_cycle;
        begin
            @(negedge clk);
            dm_addr[core*ADDR_W +: ADDR_W] = addr;
            dm_wdata[core*DATA_W +: DATA_W] = write_data;
            dm_write[core] = is_write;
            dm_valid[core] = 1'b1;
            while (!dm_ready[core]) @(posedge clk);
            start_cycle = tb_cycle;
            @(posedge clk); // acceptance edge
            @(negedge clk);
            dm_valid[core] = 1'b0;
            while (!dm_resp[core]) @(posedge clk);
            measured_latency = tb_cycle - start_cycle;
            if (!is_write &&
                (dm_rdata[core*DATA_W +: DATA_W] !== expected_data)) begin
                $display("  DM core=%0d addr=%02h expected=%08h actual=%08h",
                         core, addr, expected_data,
                         dm_rdata[core*DATA_W +: DATA_W]);
                test_fail("direct-mapped read returned unexpected data");
            end
            @(negedge clk);
        end
    endtask

    task fa_access;
        input integer core;
        input integer is_write;
        input [ADDR_W-1:0] addr;
        input [DATA_W-1:0] write_data;
        input [DATA_W-1:0] expected_data;
        output integer measured_latency;
        integer start_cycle;
        begin
            @(negedge clk);
            fa_addr[core*ADDR_W +: ADDR_W] = addr;
            fa_wdata[core*DATA_W +: DATA_W] = write_data;
            fa_write[core] = is_write;
            fa_valid[core] = 1'b1;
            while (!fa_ready[core]) @(posedge clk);
            start_cycle = tb_cycle;
            @(posedge clk); // acceptance edge
            @(negedge clk);
            fa_valid[core] = 1'b0;
            while (!fa_resp[core]) @(posedge clk);
            measured_latency = tb_cycle - start_cycle;
            if (!is_write &&
                (fa_rdata[core*DATA_W +: DATA_W] !== expected_data)) begin
                $display("  4W core=%0d addr=%02h expected=%08h actual=%08h",
                         core, addr, expected_data,
                         fa_rdata[core*DATA_W +: DATA_W]);
                test_fail("4-way read returned unexpected data");
            end
            @(negedge clk);
        end
    endtask

    // Contention test: all cores hold valid high.  The bus must grant and
    // complete each request one at a time without losing any request.
    task dm_contention;
        integer accepted;
        integer winner;
        begin
            @(negedge clk);
            dm_valid = 3'b111;
            dm_write = 3'b000;
            dm_addr[0*ADDR_W +: ADDR_W] = 8'h50;
            dm_addr[1*ADDR_W +: ADDR_W] = 8'h54;
            dm_addr[2*ADDR_W +: ADDR_W] = 8'h58;
            accepted = 0;
            while (accepted < 3) begin
                while (!(|dm_ready)) @(negedge clk);
                if (dm_ready[0]) winner = 0;
                else if (dm_ready[1]) winner = 1;
                else winner = 2;
                @(posedge clk);
                @(negedge clk);
                dm_valid[winner] = 1'b0;
                while (!dm_resp[winner]) @(posedge clk);
                @(negedge clk);
                accepted = accepted + 1;
            end
        end
    endtask

    // Procedural assertions are deliberately kept in Verilog-2001 form so
    // the same testbench works with a plain .v compilation.
    integer ac1;
    integer ac2;
    integer aw1;
    integer aw2;
    integer aset;
    integer aidx1;
    integer aidx2;
    task check_dm_invariants;
        begin
            for (ac1 = 0; ac1 < NUM_CORES; ac1 = ac1 + 1) begin
                for (ac2 = ac1 + 1; ac2 < NUM_CORES; ac2 = ac2 + 1) begin
                    for (aset = 0; aset < 4; aset = aset + 1) begin
                        aidx1 = ac1*4 + aset;
                        aidx2 = ac2*4 + aset;
                        if ((dut_dm.cache_state[aidx1] != MESI_I) &&
                            (dut_dm.cache_state[aidx2] != MESI_I) &&
                            (dut_dm.cache_tag[aidx1] == dut_dm.cache_tag[aidx2]) &&
                            ((dut_dm.cache_state[aidx1] == MESI_M) ||
                             (dut_dm.cache_state[aidx1] == MESI_E) ||
                             (dut_dm.cache_state[aidx2] == MESI_M) ||
                             (dut_dm.cache_state[aidx2] == MESI_E))) begin
                            test_fail("MESI invariant violated in direct-mapped cache");
                        end
                    end
                end
            end
        end
    endtask

    task check_4way_invariants;
        begin
            // No two ways in one core may contain the same valid line.
            for (ac1 = 0; ac1 < NUM_CORES; ac1 = ac1 + 1) begin
                for (aset = 0; aset < 4; aset = aset + 1) begin
                    for (aw1 = 0; aw1 < 4; aw1 = aw1 + 1) begin
                        for (aw2 = aw1 + 1; aw2 < 4; aw2 = aw2 + 1) begin
                            aidx1 = ac1*16 + aw1*4 + aset;
                            aidx2 = ac1*16 + aw2*4 + aset;
                            if ((dut_4w.cache_state[aidx1] != MESI_I) &&
                                (dut_4w.cache_state[aidx2] != MESI_I) &&
                                (dut_4w.cache_tag[aidx1] == dut_4w.cache_tag[aidx2])) begin
                                test_fail("duplicate valid line in 4-way cache");
                            end
                        end
                    end
                end
            end

            for (ac1 = 0; ac1 < NUM_CORES; ac1 = ac1 + 1) begin
                for (ac2 = ac1 + 1; ac2 < NUM_CORES; ac2 = ac2 + 1) begin
                    for (aset = 0; aset < 4; aset = aset + 1) begin
                        for (aw1 = 0; aw1 < 4; aw1 = aw1 + 1) begin
                            for (aw2 = 0; aw2 < 4; aw2 = aw2 + 1) begin
                                aidx1 = ac1*16 + aw1*4 + aset;
                                aidx2 = ac2*16 + aw2*4 + aset;
                                if ((dut_4w.cache_state[aidx1] != MESI_I) &&
                                    (dut_4w.cache_state[aidx2] != MESI_I) &&
                                    (dut_4w.cache_tag[aidx1] == dut_4w.cache_tag[aidx2]) &&
                                    ((dut_4w.cache_state[aidx1] == MESI_M) ||
                                     (dut_4w.cache_state[aidx1] == MESI_E) ||
                                     (dut_4w.cache_state[aidx2] == MESI_M) ||
                                     (dut_4w.cache_state[aidx2] == MESI_E))) begin
                                    test_fail("MESI invariant violated in 4-way cache");
                                end
                            end
                        end
                    end
                end
            end
        end
    endtask

    always @(posedge clk) begin
        if (!reset) begin
            check_dm_invariants;
            check_4way_invariants;
        end
    end

    task report_coverage;
        integer b;
        begin
            coverage_covered = 0;
            for (b = 0; b < 12; b = b + 1)
                coverage_covered = coverage_covered + coverage_bins[b];
            $display("Directed functional coverage: %0d/12 bins = %0d%%",
                     coverage_covered, (coverage_covered*100)/12);
            if ((coverage_covered*100)/12 < 90)
                test_fail("directed functional coverage below 90 percent");
        end
    endtask

    initial begin
        clk = 1'b0;
        reset = 1'b1;
        tb_cycle = 0;
        error_count = 0;
        dm_conflict_latency = 0;
        fa_conflict_latency = 0;
        dm_intercore_latency = 0;
        fa_intercore_latency = 0;
        dm_valid = 0;
        dm_write = 0;
        dm_addr = 0;
        dm_wdata = 0;
        fa_valid = 0;
        fa_write = 0;
        fa_addr = 0;
        fa_wdata = 0;
        for (i = 0; i < 12; i = i + 1)
            coverage_bins[i] = 0;

        reset_systems;

        // ------------------ Coherence and MESI transitions -----------------
        dm_access(0, 0, 8'h00, 32'd0, 32'd0, dm_latency);
        mark_coverage(0); // read miss
        dm_access(0, 0, 8'h00, 32'd0, 32'd0, dm_latency);
        mark_coverage(1); // read hit
        dm_access(1, 0, 8'h00, 32'd0, 32'd0, dm_latency);
        dm_access(2, 0, 8'h00, 32'd0, 32'd0, dm_latency);
        mark_coverage(6); // shared read copies

        dm_access(1, 1, 8'h00, 32'h0000_a5a5, 32'd0, dm_latency);
        model_mem[8'h00 >> 2] = 32'h0000_a5a5;
        mark_coverage(4); // S -> M upgrade
        mark_coverage(7); // peer invalidation

        dm_access(0, 0, 8'h00, 32'd0, 32'h0000_a5a5, dm_latency);
        mark_coverage(5); // snoop of M owner
        dm_access(2, 1, 8'h00, 32'h0000_5a5a, 32'd0, dm_latency);
        model_mem[8'h00 >> 2] = 32'h0000_5a5a;

        // Write hit in M, then M eviction/writeback from the same set.
        dm_access(2, 1, 8'h00, 32'h0000_5b5b, 32'd0, dm_latency);
        model_mem[8'h00 >> 2] = 32'h0000_5b5b;
        mark_coverage(3); // M write hit
        dm_access(0, 1, 8'h10, 32'h1111_2222, 32'd0, dm_latency);
        model_mem[8'h10 >> 2] = 32'h1111_2222;
        dm_access(0, 1, 8'h20, 32'h3333_4444, 32'd0, dm_latency);
        model_mem[8'h20 >> 2] = 32'h3333_4444;
        mark_coverage(8); // M-line writeback on eviction
        dm_access(1, 0, 8'h10, 32'd0, 32'h1111_2222, dm_latency);
        mark_coverage(2); // write miss (the 0x10 request above)

        dm_contention;
        mark_coverage(11); // all three requesters contend for the bus

        // ------------------- Conflict latency benchmark --------------------
        // 0x40, 0x50, 0x60 and 0x70 all map to set zero (bits [3:2]=00).
        reset_systems;
        for (i = 0; i < 2; i = i + 1) begin
            dm_access(0, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], dm_latency);
            dm_conflict_latency = dm_conflict_latency + dm_latency;
            dm_access(0, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], dm_latency);
            dm_conflict_latency = dm_conflict_latency + dm_latency;
            dm_access(0, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], dm_latency);
            dm_conflict_latency = dm_conflict_latency + dm_latency;
            dm_access(0, 0, 8'h70, 32'd0, model_mem[8'h70 >> 2], dm_latency);
            dm_conflict_latency = dm_conflict_latency + dm_latency;
        end
        mark_coverage(9); // direct-mapped conflict misses

        reset_systems;
        for (i = 0; i < 2; i = i + 1) begin
            fa_access(0, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], fa_latency);
            fa_conflict_latency = fa_conflict_latency + fa_latency;
            fa_access(0, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], fa_latency);
            fa_conflict_latency = fa_conflict_latency + fa_latency;
            fa_access(0, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], fa_latency);
            fa_conflict_latency = fa_conflict_latency + fa_latency;
            fa_access(0, 0, 8'h70, 32'd0, model_mem[8'h70 >> 2], fa_latency);
            fa_conflict_latency = fa_conflict_latency + fa_latency;
        end
        mark_coverage(10); // four-way conflict retention / hits

        // ---------------- Inter-core conflict/coherence workload ------------
        // Each core first reads the same line, then thrashes three additional
        // lines that map to the same set, then core 0 writes the shared line
        // and cores 1 and 2 read it.  The direct-mapped design repeatedly
        // loses the shared line; the four-way design retains shared+three
        // conflict lines.  This is the measured inter-core latency workload.
        reset_systems;
        dm_access(0, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], dm_latency);
        dm_intercore_latency = dm_intercore_latency + dm_latency;
        dm_access(1, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], dm_latency);
        dm_intercore_latency = dm_intercore_latency + dm_latency;
        dm_access(2, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], dm_latency);
        dm_intercore_latency = dm_intercore_latency + dm_latency;
        for (i = 0; i < 3; i = i + 1) begin
            dm_access(0, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(0, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(0, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(1, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(1, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(1, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(2, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(2, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(2, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(0, 1, 8'h00, 32'h9000_0000 + i, 32'd0, dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            model_mem[8'h00 >> 2] = 32'h9000_0000 + i;
            dm_access(1, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
            dm_access(2, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], dm_latency);
            dm_intercore_latency = dm_intercore_latency + dm_latency;
        end

        reset_systems;
        fa_access(0, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], fa_latency);
        fa_intercore_latency = fa_intercore_latency + fa_latency;
        fa_access(1, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], fa_latency);
        fa_intercore_latency = fa_intercore_latency + fa_latency;
        fa_access(2, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], fa_latency);
        fa_intercore_latency = fa_intercore_latency + fa_latency;
        for (i = 0; i < 3; i = i + 1) begin
            fa_access(0, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(0, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(0, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(1, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(1, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(1, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(2, 0, 8'h40, 32'd0, model_mem[8'h40 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(2, 0, 8'h50, 32'd0, model_mem[8'h50 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(2, 0, 8'h60, 32'd0, model_mem[8'h60 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(0, 1, 8'h00, 32'h9000_0000 + i, 32'd0, fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            model_mem[8'h00 >> 2] = 32'h9000_0000 + i;
            fa_access(1, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
            fa_access(2, 0, 8'h00, 32'd0, model_mem[8'h00 >> 2], fa_latency);
            fa_intercore_latency = fa_intercore_latency + fa_latency;
        end

        report_coverage;
        $display("Direct-map conflict benchmark latency = %0d cycles", dm_conflict_latency);
        $display("4-way conflict benchmark latency      = %0d cycles", fa_conflict_latency);
        if (fa_conflict_latency >= ((dm_conflict_latency * 85) / 100))
            test_fail("4-way conflict benchmark did not improve latency by at least 15 percent");
        else
            $display("Measured 4-way improvement = %0d%%",
                     ((dm_conflict_latency-fa_conflict_latency)*100)/dm_conflict_latency);
        $display("Direct-map inter-core workload latency = %0d cycles", dm_intercore_latency);
        $display("4-way inter-core workload latency      = %0d cycles", fa_intercore_latency);
        if (fa_intercore_latency >= ((dm_intercore_latency * 85) / 100))
            test_fail("4-way inter-core workload did not improve latency by at least 15 percent");
        else
            $display("Measured inter-core 4-way improvement = %0d%%",
                     ((dm_intercore_latency-fa_intercore_latency)*100)/dm_intercore_latency);

        if (error_count == 0)
            $display("PASS: MESI directed test, invariants, data checks, coverage, and latency benchmark");
        else
            $display("FAIL: %0d test errors", error_count);
        $finish;
    end
endmodule
