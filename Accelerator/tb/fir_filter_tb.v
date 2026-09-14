`timescale 1ns/1ps

module fir_filter_tb;

    localparam DATA_W    = 16;
    localparam COEF_W    = 16;
    localparam ACC_W     = 40;
    localparam TAPS      = 8;
    localparam FRAC_BITS = 15;

    reg clk;
    reg rst_n;
    reg sample_valid;
    reg signed [DATA_W-1:0] x_in;
    reg [TAPS*COEF_W-1:0] coeffs_in;

    integer errors;
    integer i;

    // ---------------- Two instances: sequential vs. parallel ----------------
    wire ready_seq, y_valid_seq;
    wire signed [DATA_W-1:0] y_out_seq;

    fir_filter #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .TAPS(TAPS), .NUM_MACS(1), .FRAC_BITS(FRAC_BITS)
    ) dut_seq (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .x_in(x_in), .coeffs_in(coeffs_in),
        .ready(ready_seq), .y_out(y_out_seq), .y_valid(y_valid_seq)
    );

    wire ready_par, y_valid_par;
    wire signed [DATA_W-1:0] y_out_par;

    fir_filter #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .TAPS(TAPS), .NUM_MACS(TAPS), .FRAC_BITS(FRAC_BITS)
    ) dut_par (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .x_in(x_in), .coeffs_in(coeffs_in),
        .ready(ready_par), .y_out(y_out_par), .y_valid(y_valid_par)
    );

    always #5 clk = ~clk;

    // ---------------- helper: set coefficient i (Q1.15) ----------------
    task set_coeff;
        input integer idx;
        input signed [COEF_W-1:0] val;
        begin
            coeffs_in[idx*COEF_W +: COEF_W] = val;
        end
    endtask

    // ---------------- helper: push one sample and wait for both outputs ----
    task push_sample;
        input signed [DATA_W-1:0] sample;
        output signed [DATA_W-1:0] y_seq;
        output signed [DATA_W-1:0] y_par;
        reg got_seq, got_par;
        begin
            @(posedge clk);
            x_in         = sample;
            sample_valid = 1'b1;
            @(posedge clk);
            sample_valid = 1'b0;

            got_seq = 1'b0;
            got_par = 1'b0;
            y_seq   = {DATA_W{1'bx}};
            y_par   = {DATA_W{1'bx}};

            while (!(got_seq && got_par)) begin
                @(posedge clk);
                if (y_valid_seq) begin y_seq = y_out_seq; got_seq = 1'b1; end
                if (y_valid_par) begin y_par = y_out_par; got_par = 1'b1; end
            end
        end
    endtask

    reg signed [DATA_W-1:0] y_seq, y_par;
    reg signed [DATA_W-1:0] expected;

    initial begin
        clk = 0; rst_n = 0; sample_valid = 0; x_in = 0; coeffs_in = 0;
        errors = 0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // =========================================================
        // Test 1: single-tap, h0 = 0.5 (Q1.15 = 16384), rest = 0.
        // Since only tap 0 is nonzero, y[n] = x[n] >>> 1 exactly,
        // independent of sample history.
        // =========================================================
        coeffs_in = 0;
        set_coeff(0, 16'sd16384);

        push_sample(16'sd1000, y_seq, y_par);
        expected = 16'sd1000 >>> 1;
        if (y_seq !== expected || y_par !== expected) begin
            $display("FAIL T1a: expected=%0d seq=%0d par=%0d", expected, y_seq, y_par);
            errors = errors + 1;
        end else
            $display("PASS T1a: y=%0d (seq and par agree)", y_seq);

        push_sample(-16'sd2000, y_seq, y_par);
        expected = -16'sd2000 >>> 1;
        if (y_seq !== expected || y_par !== expected) begin
            $display("FAIL T1b: expected=%0d seq=%0d par=%0d", expected, y_seq, y_par);
            errors = errors + 1;
        end else
            $display("PASS T1b: y=%0d (seq and par agree)", y_seq);

        // =========================================================
        // Test 2: 2-tap moving average, h0=h1=0.5, rest = 0.
        // y[n] = (x[n] + x[n-1]) >>> 1
        // Reset the pipeline first for a clean history.
        // =========================================================
        rst_n = 0; @(posedge clk); @(posedge clk); rst_n = 1; @(posedge clk);

        coeffs_in = 0;
        set_coeff(0, 16'sd16384);
        set_coeff(1, 16'sd16384);

        push_sample(16'sd100, y_seq, y_par);   // x[-1]=0 (reset) -> (100+0)>>>1
        expected = (16'sd100 + 16'sd0) >>> 1;
        if (y_seq !== expected || y_par !== expected) begin
            $display("FAIL T2a: expected=%0d seq=%0d par=%0d", expected, y_seq, y_par);
            errors = errors + 1;
        end else
            $display("PASS T2a: y=%0d (seq and par agree)", y_seq);

        push_sample(16'sd200, y_seq, y_par);   // (200+100)>>>1
        expected = (16'sd200 + 16'sd100) >>> 1;
        if (y_seq !== expected || y_par !== expected) begin
            $display("FAIL T2b: expected=%0d seq=%0d par=%0d", expected, y_seq, y_par);
            errors = errors + 1;
        end else
            $display("PASS T2b: y=%0d (seq and par agree)", y_seq);

        push_sample(16'sd300, y_seq, y_par);   // (300+200)>>>1
        expected = (16'sd300 + 16'sd200) >>> 1;
        if (y_seq !== expected || y_par !== expected) begin
            $display("FAIL T2c: expected=%0d seq=%0d par=%0d", expected, y_seq, y_par);
            errors = errors + 1;
        end else
            $display("PASS T2c: y=%0d (seq and par agree)", y_seq);

        push_sample(-16'sd400, y_seq, y_par);  // (-400+300)>>>1
        expected = (-16'sd400 + 16'sd300) >>> 1;
        if (y_seq !== expected || y_par !== expected) begin
            $display("FAIL T2d: expected=%0d seq=%0d par=%0d", expected, y_seq, y_par);
            errors = errors + 1;
        end else
            $display("PASS T2d: y=%0d (seq and par agree)", y_seq);

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #5000;
        $display("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
