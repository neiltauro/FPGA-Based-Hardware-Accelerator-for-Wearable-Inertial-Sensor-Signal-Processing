`timescale 1ns/1ps

// =============================================================================
// accelerator_dataset_tb.v
//
// Validates accelerator_top against the actual generated dataset and FIR
// coefficients (rtl/data/, produced by the python/ scripts) and compares
// every sample's output against the Python reference model's output
// (rtl/data/expected_output.hex). This is the "baseline data path"
// integration test described in Section 9.1 of the project proposal:
//   CSV -> Python preprocessing -> .mem file -> FPGA BRAM -> Accelerator
//
// The input BRAM is preloaded directly via accelerator_top's IN_INIT_FILE
// parameter (a synthesizable $readmemh initial block, not a simulation-only
// backdoor), so this test exercises the same BRAM-preload mechanism that
// would be used to bring up the design on hardware.
//
// Run from the rtl/ directory so the relative data/ paths resolve.
// Compile with -DARCH_PARALLEL to test Architecture B instead of A.
// =============================================================================

module accelerator_dataset_tb;

    localparam DATA_W     = 16;
    localparam COEF_W     = 16;
    localparam ACC_W      = 40;
    localparam TAPS       = 8;
    localparam FRAC_BITS  = 15;
    localparam OUT_W      = 32;
    localparam NUM_SAMPLES = 64;
    localparam ADDR_W     = 6;

    reg clk;
    reg rst_n;
    reg start;
    reg [ADDR_W-1:0] out_rd_addr;

    wire busy, done;
    wire [OUT_W-1:0] out_rd_data;

    // Coefficients loaded from the generated hex file (see below).
    reg [TAPS*COEF_W-1:0] coeffs_mem [0:0];
    wire [TAPS*COEF_W-1:0] coeffs_in = coeffs_mem[0];

    integer errors;
    integer i;

    accelerator_top #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W), .TAPS(TAPS),
        .FRAC_BITS(FRAC_BITS), .OUT_W(OUT_W),
        `ifdef ARCH_PARALLEL
        .NUM_MACS_FILT(TAPS), .NUM_MACS_VEC(3),
        `else
        .NUM_MACS_FILT(1), .NUM_MACS_VEC(1),
        `endif
        .NUM_SAMPLES(NUM_SAMPLES), .ADDR_W(ADDR_W),
        .IN_INIT_FILE("data/input.mem")
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .coeffs_in(coeffs_in),
        .in_wr_en(1'b0), .in_wr_addr({ADDR_W{1'b0}}), .in_wr_data({3*DATA_W{1'b0}}),
        .out_rd_addr(out_rd_addr), .out_rd_data(out_rd_data)
    );

    always #5 clk = ~clk;

    reg [OUT_W-1:0] expected [0:NUM_SAMPLES-1];
    reg [OUT_W-1:0] got;

    initial begin
        $readmemh("data/coeffs_pack.hex", coeffs_mem);
        $readmemh("data/expected_output.hex", expected);

        clk = 0; rst_n = 0; start = 0; out_rd_addr = 0;
        errors = 0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Input BRAM was preloaded at elaboration time via IN_INIT_FILE;
        // no host writes are needed for this test.
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        $display("PASS: done pulsed - accelerator completed %0d samples", NUM_SAMPLES);
        @(posedge clk);

        for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
            @(posedge clk);
            out_rd_addr = i[ADDR_W-1:0];
            @(posedge clk);
            #1;
            got = out_rd_data;
            if (got !== expected[i]) begin
                $display("FAIL: sample %0d mag_sq=%0d expected=%0d", i, got, expected[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0) begin
            $display("All %0d samples matched the Python reference model exactly.", NUM_SAMPLES);
            $display("\n=== ALL TESTS PASSED (real-data validation) ===");
        end else begin
            $display("\n=== %0d / %0d SAMPLE(S) FAILED ===", errors, NUM_SAMPLES);
        end

        $finish;
    end

    initial begin
        #50000;
        $display("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
