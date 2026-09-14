`timescale 1ns/1ps

module mac_engine_tb;

    localparam DATA_W   = 16;
    localparam COEF_W   = 16;
    localparam ACC_W    = 40;
    localparam NUM_TAPS = 8;

    // Test vectors: a = [1,2,3,4,5,6,7,8], b = [8,7,6,5,4,3,2,1]
    // expected dot product = 1*8+2*7+3*6+4*5+5*4+6*3+7*2+8*1
    //                       = 8+14+18+20+20+18+14+8 = 120
    localparam signed [ACC_W-1:0] EXPECTED = 120;

    reg clk;
    reg rst_n;
    reg start;
    reg [NUM_TAPS*DATA_W-1:0] a_in;
    reg [NUM_TAPS*COEF_W-1:0] b_in;

    integer errors;
    integer i;

    task load_vectors;
        begin
            for (i = 0; i < NUM_TAPS; i = i + 1) begin
                a_in[i*DATA_W +: DATA_W] = i + 1;        // 1..8
                b_in[i*COEF_W +: COEF_W] = NUM_TAPS - i; // 8..1
            end
        end
    endtask

    // ---------------- Instance 1: sequential (NUM_MACS = 1) ----------------
    wire signed [ACC_W-1:0] result_seq;
    wire valid_seq, busy_seq;
    integer latency_seq;

    mac_engine #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .NUM_TAPS(NUM_TAPS), .NUM_MACS(1)
    ) dut_seq (
        .clk(clk), .rst_n(rst_n), .start(start),
        .a_in(a_in), .b_in(b_in),
        .result(result_seq), .valid(valid_seq), .busy(busy_seq)
    );

    // ---------------- Instance 2: parallel (NUM_MACS = 8) ----------------
    wire signed [ACC_W-1:0] result_par;
    wire valid_par, busy_par;
    integer latency_par;

    mac_engine #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .NUM_TAPS(NUM_TAPS), .NUM_MACS(8)
    ) dut_par (
        .clk(clk), .rst_n(rst_n), .start(start),
        .a_in(a_in), .b_in(b_in),
        .result(result_par), .valid(valid_par), .busy(busy_par)
    );

    // ---------------- Instance 3: intermediate (NUM_MACS = 4) --------------
    wire signed [ACC_W-1:0] result_mid;
    wire valid_mid, busy_mid;
    integer latency_mid;

    mac_engine #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .NUM_TAPS(NUM_TAPS), .NUM_MACS(4)
    ) dut_mid (
        .clk(clk), .rst_n(rst_n), .start(start),
        .a_in(a_in), .b_in(b_in),
        .result(result_mid), .valid(valid_mid), .busy(busy_mid)
    );

    // clock
    always #5 clk = ~clk;

    // latency counters (cycles from start to valid)
    initial begin
        latency_seq = 0; latency_par = 0; latency_mid = 0;
    end

    always @(posedge clk) begin
        if (start) begin
            latency_seq <= 0; latency_par <= 0; latency_mid <= 0;
        end else begin
            if (busy_seq || valid_seq) latency_seq <= latency_seq + 1;
            if (busy_par || valid_par) latency_par <= latency_par + 1;
            if (busy_mid || valid_mid) latency_mid <= latency_mid + 1;
        end
    end

    initial begin
        clk   = 0;
        rst_n = 0;
        start = 0;
        errors = 0;
        load_vectors;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Pulse start for one cycle
        start = 1;
        @(posedge clk);
        start = 0;

        // Wait for all three to finish (parallel finishes first)
        wait (valid_seq);
        @(posedge clk);

        // ---------------- Checks ----------------
        if (result_seq !== EXPECTED) begin
            $display("FAIL: sequential (NUM_MACS=1) result=%0d expected=%0d", result_seq, EXPECTED);
            errors = errors + 1;
        end else begin
            $display("PASS: sequential (NUM_MACS=1) result=%0d, latency=%0d cycles", result_seq, latency_seq);
        end

        if (result_par !== EXPECTED) begin
            $display("FAIL: parallel (NUM_MACS=8) result=%0d expected=%0d", result_par, EXPECTED);
            errors = errors + 1;
        end else begin
            $display("PASS: parallel (NUM_MACS=8) result=%0d, latency=%0d cycles", result_par, latency_par);
        end

        if (result_mid !== EXPECTED) begin
            $display("FAIL: intermediate (NUM_MACS=4) result=%0d expected=%0d", result_mid, EXPECTED);
            errors = errors + 1;
        end else begin
            $display("PASS: intermediate (NUM_MACS=4) result=%0d, latency=%0d cycles", result_mid, latency_mid);
        end

        // Expected latency relationship: seq(8) > mid(4) > par(2), roughly NUM_TAPS/NUM_MACS + 1
        if (!(latency_seq > latency_mid && latency_mid > latency_par)) begin
            $display("FAIL: latency ordering incorrect (seq=%0d mid=%0d par=%0d)",
                       latency_seq, latency_mid, latency_par);
            errors = errors + 1;
        end else begin
            $display("PASS: latency scales with parallelism as expected (seq=%0d > mid=%0d > par=%0d)",
                       latency_seq, latency_mid, latency_par);
        end

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    // safety timeout
    initial begin
        #2000;
        $display("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
