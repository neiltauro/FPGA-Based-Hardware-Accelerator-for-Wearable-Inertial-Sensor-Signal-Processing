`timescale 1ns/1ps

// =============================================================================
// accelerator_top_extended_tb.v
//
// Extended-coverage end-to-end test for accelerator_top: 32 samples across
// four deliberately varied segments, run through a real 4-tap moving-average
// FIR filter (not the single-tap shortcut used in accelerator_top_tb.v), so
// the filter's history actually matters across many cycles. Every sample's
// inputs and RTL/reference outputs are printed, not just a pass/fail count,
// so you can see the full range of values the accelerator produces.
//
// Coefficients: h = [0.2, 0.3, 0.3, 0.2, 0, 0, 0, 0] in Q1.15
//   h0=6554, h1=9830, h2=9830, h3=6554  (sum = 32768 = exactly 1.0 DC gain)
//
// Dataset segments (indices):
//   0-7   : increasing ramps, distinct slope per axis
//   8-15  : descending ramps that cross zero (sign changes mid-segment)
//   16-23 : pseudo-random values ($random with a fixed seed, reproducible)
//   24-31 : hand-picked edge cases (max/min 16-bit, zero, alternating signs)
//
// The reference model below is a generic TAPS-tap streaming FIR (matching
// fir_filter.v's shift-register + multiply-accumulate + rescale + saturate
// exactly) rather than the algebraic shortcut used for the single-tap case
// in accelerator_top_tb.v, since a real multi-tap filter's output depends
// on sample history and can't be computed independently per sample.
//
// NOTE: this file has been carefully hand-verified against the same logic
// already proven correct in fir_filter_tb.v / vector_engine_tb.v /
// accelerator_dataset_tb.v, but has NOT itself been compiled or simulated
// (Icarus Verilog was not available in the environment that produced this
// file). Please compile and run it yourself and report back if anything
// doesn't build cleanly.
// =============================================================================

module accelerator_top_extended_tb;

    localparam DATA_W      = 16;
    localparam COEF_W      = 16;
    localparam ACC_W       = 40;
    localparam TAPS        = 8;
    localparam FRAC_BITS   = 15;
    localparam OUT_W       = 32;
    localparam NUM_SAMPLES = 32;
    localparam ADDR_W      = 5;

    reg clk;
    reg rst_n;
    reg start;
    reg [TAPS*COEF_W-1:0] coeffs_in;
    reg in_wr_en;
    reg [ADDR_W-1:0] in_wr_addr;
    reg [3*DATA_W-1:0] in_wr_data;
    reg [ADDR_W-1:0] out_rd_addr;

    wire busy, done;
    wire [OUT_W-1:0] out_rd_data;

    integer errors;
    integer i;    // loop var: host-write and readback loops
    integer gi;   // loop var: dataset/coefficient generation
    integer seed; // fixed seed for reproducible pseudo-random samples

    accelerator_top #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W), .TAPS(TAPS),
        .FRAC_BITS(FRAC_BITS), .OUT_W(OUT_W),
        `ifdef ARCH_PARALLEL
        .NUM_MACS_FILT(TAPS), .NUM_MACS_VEC(3),
        `else
        .NUM_MACS_FILT(1), .NUM_MACS_VEC(1),
        `endif
        .NUM_SAMPLES(NUM_SAMPLES), .ADDR_W(ADDR_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .coeffs_in(coeffs_in),
        .in_wr_en(in_wr_en), .in_wr_addr(in_wr_addr), .in_wr_data(in_wr_data),
        .out_rd_addr(out_rd_addr), .out_rd_data(out_rd_data)
    );

    always #5 clk = ~clk;

    // ---------------- Dataset and expected-output storage ------------------
    reg signed [DATA_W-1:0] test_ax [0:NUM_SAMPLES-1];
    reg signed [DATA_W-1:0] test_ay [0:NUM_SAMPLES-1];
    reg signed [DATA_W-1:0] test_az [0:NUM_SAMPLES-1];
    reg [OUT_W-1:0] expected [0:NUM_SAMPLES-1];
    reg [OUT_W-1:0] got;

    // ---------------- Reference-model state (mirrors fir_filter.v) --------
    reg signed [COEF_W-1:0] h [0:TAPS-1];        // filter coefficients
    reg signed [DATA_W-1:0] win_x [0:TAPS-1];    // per-axis tapped delay lines
    reg signed [DATA_W-1:0] win_y [0:TAPS-1];
    reg signed [DATA_W-1:0] win_z [0:TAPS-1];

    // Generic streaming FIR step for one axis: shifts x_in into that axis's
    // window (index 0 = newest), computes sum(h[k]*window[k]), rescales by
    // an arithmetic right shift of FRAC_BITS, and saturates to DATA_W bits
    // -- bit-exact with fir_filter.v's datapath.
    task fir_step;
        input integer axis;                      // 0=X, 1=Y, 2=Z
        input signed [DATA_W-1:0] x_in;
        output signed [DATA_W-1:0] y_out;
        integer k;
        reg signed [ACC_W-1:0] acc;
        reg signed [ACC_W-1:0] rescaled;
        begin
            case (axis)
                0: begin
                    for (k = TAPS-1; k > 0; k = k - 1) win_x[k] = win_x[k-1];
                    win_x[0] = x_in;
                end
                1: begin
                    for (k = TAPS-1; k > 0; k = k - 1) win_y[k] = win_y[k-1];
                    win_y[0] = x_in;
                end
                2: begin
                    for (k = TAPS-1; k > 0; k = k - 1) win_z[k] = win_z[k-1];
                    win_z[0] = x_in;
                end
            endcase

            acc = 0;
            for (k = 0; k < TAPS; k = k + 1) begin
                case (axis)
                    0: acc = acc + (h[k] * win_x[k]);
                    1: acc = acc + (h[k] * win_y[k]);
                    2: acc = acc + (h[k] * win_z[k]);
                endcase
            end

            rescaled = acc >>> FRAC_BITS;

            if (rescaled > 32767)
                y_out = 16'sd32767;
            else if (rescaled < -32768)
                y_out = -16'sd32768;
            else
                y_out = rescaled[DATA_W-1:0];
        end
    endtask

    // Runs the full dataset through the reference model once, populating
    // expected[]. Must be called after h[] and test_ax/ay/az[] are set.
    task compute_expected;
        integer n;
        reg signed [DATA_W-1:0] fx, fy, fz;
        reg signed [63:0] sqsum;
        begin
            for (n = 0; n < NUM_SAMPLES; n = n + 1) begin
                fir_step(0, test_ax[n], fx);
                fir_step(1, test_ay[n], fy);
                fir_step(2, test_az[n], fz);
                sqsum = (fx * fx) + (fy * fy) + (fz * fz);
                expected[n] = sqsum[OUT_W-1:0];
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; start = 0; coeffs_in = 0;
        in_wr_en = 0; in_wr_addr = 0; in_wr_data = 0; out_rd_addr = 0;
        errors = 0;

        // ---------------- Coefficients: 4-tap moving average, Q1.15 -------
        coeffs_in[0*COEF_W +: COEF_W] = 16'sd6554;  // 0.2
        coeffs_in[1*COEF_W +: COEF_W] = 16'sd9830;  // 0.3
        coeffs_in[2*COEF_W +: COEF_W] = 16'sd9830;  // 0.3
        coeffs_in[3*COEF_W +: COEF_W] = 16'sd6554;  // 0.2
        // taps 4-7 remain 0 from the coeffs_in = 0 initialization above

        for (gi = 0; gi < TAPS; gi = gi + 1) begin
            h[gi] = $signed(coeffs_in[gi*COEF_W +: COEF_W]);
        end

        // Explicitly zero the reference model's FIR windows, matching
        // fir_filter.v's own reset behavior (window <= all-zero on rst_n).
        // Without this, win_x/win_y/win_z start as X (uninitialized reg
        // array elements), and since h[4..7]=0, the multiply h[k]*win[k]
        // would compute 0*X=X (NOT 0 -- Verilog's 4-state arithmetic
        // propagates X pessimistically through *), contaminating the
        // accumulator with X until every window position has been shifted
        // into at least once (TAPS=8 calls per axis).
        for (gi = 0; gi < TAPS; gi = gi + 1) begin
            win_x[gi] = {DATA_W{1'b0}};
            win_y[gi] = {DATA_W{1'b0}};
            win_z[gi] = {DATA_W{1'b0}};
        end

        // ---------------- Segment A (0-7): increasing ramps ----------------
        for (gi = 0; gi < 8; gi = gi + 1) begin
            test_ax[gi] = 200  * (gi + 1);
            test_ay[gi] = 300  * (gi + 1);
            test_az[gi] = -150 * (gi + 1);
        end

        // ---------------- Segment B (8-15): descending, sign-crossing -----
        for (gi = 0; gi < 8; gi = gi + 1) begin
            test_ax[8+gi]  = 1000 - 300 * gi;   // 1000 down to -1100
            test_ay[8+gi]  = -500 + 250 * gi;   // -500 up to 1250
            test_az[8+gi]  = 2000 - 500 * gi;   // 2000 down to -1500
        end

        // ---------------- Segment C (16-23): seeded pseudo-random ----------
        seed = 32'hC0FFEE01;
        for (gi = 0; gi < 8; gi = gi + 1) begin
            test_ax[16+gi] = $random(seed);
            test_ay[16+gi] = $random(seed);
            test_az[16+gi] = $random(seed);
        end

        // ---------------- Segment D (24-31): hand-picked edge cases --------
        test_ax[24] = 16'sd32767;  test_ay[24] = 16'sd32767;  test_az[24] = 16'sd32767;  // max positive, all axes
        test_ax[25] = -16'sd32768; test_ay[25] = -16'sd32768; test_az[25] = -16'sd32768; // max negative, all axes
        test_ax[26] = 16'sd0;      test_ay[26] = 16'sd0;      test_az[26] = 16'sd0;      // all zero
        test_ax[27] = 16'sd32767;  test_ay[27] = -16'sd32768; test_az[27] = 16'sd0;      // mixed extremes
        test_ax[28] = -16'sd32768; test_ay[28] = 16'sd32767;  test_az[28] = 16'sd0;      // mixed extremes, flipped
        test_ax[29] = 16'sd1;      test_ay[29] = -16'sd1;     test_az[29] = 16'sd1;      // smallest nonzero
        test_ax[30] = -16'sd1;     test_ay[30] = 16'sd1;      test_az[30] = -16'sd1;     // smallest nonzero, flipped
        test_ax[31] = 16'sd16384;  test_ay[31] = -16'sd16384; test_az[31] = 16'sd16384;  // +-0.5

        compute_expected;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---------------- load dataset into input BRAM (host write) -------
        for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
            @(posedge clk);
            in_wr_en   = 1'b1;
            in_wr_addr = i[ADDR_W-1:0];
            in_wr_data = {test_az[i], test_ay[i], test_ax[i]}; // {Az, Ay, Ax}
        end
        @(posedge clk);
        in_wr_en = 1'b0;

        // ---------------- run the accelerator -------------------------------
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        $display("PASS: done pulsed - accelerator completed %0d samples\n", NUM_SAMPLES);
        @(posedge clk);

        // ---------------- read back and print every sample -----------------
        $display("--- Per-sample results (%0d samples) ---", NUM_SAMPLES);
        $display(" idx        Ax        Ay        Az |       mag_sq (RTL)       mag_sq (expected)   status");
        $display("-----------------------------------------------------------------------------------------");
        for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
            @(posedge clk);
            out_rd_addr = i[ADDR_W-1:0];
            @(posedge clk); // 1-cycle BRAM read latency
            #1;             // let the BRAM's nonblocking update settle before sampling
            got = out_rd_data;
            if (got !== expected[i]) begin
                $display("[%20d] %9d %9d %9d | %20d %20d   MISMATCH",
                          i, test_ax[i], test_ay[i], test_az[i], got, expected[i]);
                errors = errors + 1;
            end else begin
                $display("[%20d] %9d %9d %9d | %20d %20d   ok",
                          i, test_ax[i], test_ay[i], test_az[i], got, expected[i]);
            end
        end

        $display("-----------------------------------------------------------------------------------------");
        if (errors == 0)
            $display("\n=== ALL %0d SAMPLES PASSED (extended accelerator_top coverage) ===", NUM_SAMPLES);
        else
            $display("\n=== %0d / %0d SAMPLE(S) FAILED ===", errors, NUM_SAMPLES);

        $finish;
    end

    initial begin
        #60000;
        $display("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
