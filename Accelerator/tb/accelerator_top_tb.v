`timescale 1ns/1ps

module accelerator_top_tb;

    localparam DATA_W     = 16;
    localparam COEF_W     = 16;
    localparam ACC_W      = 40;
    localparam TAPS       = 8;
    localparam FRAC_BITS  = 15;
    localparam OUT_W      = 32;
    localparam NUM_SAMPLES = 4;
    localparam ADDR_W     = 2;

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
    integer i;

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

    // -------- reference model: same fixed-point math as the hardware ----
    // h0 = 0.5 (Q1.15 = 16384), all other taps = 0
    // => filtered_axis[n] = axis_in[n] >>> 1  (independent of history)
    // => mag_sq[n] = fAx^2 + fAy^2 + fAz^2   (unscaled Q2.30 domain)
    reg signed [DATA_W-1:0] test_ax [0:NUM_SAMPLES-1];
    reg signed [DATA_W-1:0] test_ay [0:NUM_SAMPLES-1];
    reg signed [DATA_W-1:0] test_az [0:NUM_SAMPLES-1];
    reg [OUT_W-1:0] expected [0:NUM_SAMPLES-1];

    reg signed [DATA_W-1:0] fax, fay, faz;
    reg [OUT_W-1:0] got;

    task compute_expected;
        integer n;
        begin
            for (n = 0; n < NUM_SAMPLES; n = n + 1) begin
                fax = test_ax[n] >>> 1;
                fay = test_ay[n] >>> 1;
                faz = test_az[n] >>> 1;
                expected[n] = (fax * fax) + (fay * fay) + (faz * faz);
            end
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; start = 0; coeffs_in = 0;
        in_wr_en = 0; in_wr_addr = 0; in_wr_data = 0; out_rd_addr = 0;
        errors = 0;

        // ---------------- test dataset ----------------
        test_ax[0] = 16'sd1000;  test_ay[0] = 16'sd2000;   test_az[0] = -16'sd1000;
        test_ax[1] = 16'sd0;     test_ay[1] = 16'sd0;      test_az[1] = 16'sd0;
        test_ax[2] = 16'sd32767; test_ay[2] = -16'sd32768; test_az[2] = 16'sd100;
        test_ax[3] = -16'sd500;  test_ay[3] = 16'sd500;    test_az[3] = 16'sd500;

        compute_expected;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // ---------------- set filter coefficients: h0 = 0.5, rest 0 ----
        coeffs_in = 0;
        coeffs_in[0*COEF_W +: COEF_W] = 16'sd16384;

        // ---------------- load dataset into input BRAM (host write) ----
        for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
            @(posedge clk);
            in_wr_en   = 1'b1;
            in_wr_addr = i[ADDR_W-1:0];
            in_wr_data = {test_az[i], test_ay[i], test_ax[i]}; // {Az, Ay, Ax}
        end
        @(posedge clk);
        in_wr_en = 1'b0;

        // ---------------- run the accelerator ----------------
        @(posedge clk);
        start = 1'b1;
        @(posedge clk);
        start = 1'b0;

        wait (done);
        $display("PASS: done pulsed - accelerator completed %0d samples", NUM_SAMPLES);
        @(posedge clk);

        // ---------------- read back and check results ----------------
        for (i = 0; i < NUM_SAMPLES; i = i + 1) begin
            @(posedge clk);
            out_rd_addr = i[ADDR_W-1:0];
            @(posedge clk); // 1-cycle BRAM read latency
            #1;             // let the BRAM's nonblocking update settle before sampling
            got = out_rd_data;
            if (got !== expected[i]) begin
                $display("FAIL: sample %0d mag_sq=%0d expected=%0d", i, got, expected[i]);
                errors = errors + 1;
            end else begin
                $display("PASS: sample %0d mag_sq=%0d (matches reference)", i, got);
            end
        end

        if (errors == 0)
            $display("\n=== ALL TESTS PASSED (end-to-end accelerator_top) ===");
        else
            $display("\n=== %0d TEST(S) FAILED ===", errors);

        $finish;
    end

    initial begin
        #10000;
        $display("TIMEOUT: simulation did not complete");
        $finish;
    end

endmodule
