`timescale 1ns/1ps

module vector_engine_tb;

    localparam DATA_W = 16;
    localparam ACC_W  = 40;
    localparam OUT_W  = 32;

    reg clk;
    reg rst_n;
    reg sample_valid;
    reg signed [DATA_W-1:0] ax_in, ay_in, az_in;

    integer errors;

    // ---------------- Two instances: sequential vs. parallel ----------------
    wire ready_seq, valid_seq;
    wire [OUT_W-1:0] mag_seq;

    vector_engine #(
        .DATA_W(DATA_W), .ACC_W(ACC_W), .NUM_MACS(1), .OUT_W(OUT_W)
    ) dut_seq (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .ax_in(ax_in), .ay_in(ay_in), .az_in(az_in),
        .ready(ready_seq), .mag_sq_out(mag_seq), .mag_sq_valid(valid_seq)
    );

    wire ready_par, valid_par;
    wire [OUT_W-1:0] mag_par;

    vector_engine #(
        .DATA_W(DATA_W), .ACC_W(ACC_W), .NUM_MACS(3), .OUT_W(OUT_W)
    ) dut_par (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .ax_in(ax_in), .ay_in(ay_in), .az_in(az_in),
        .ready(ready_par), .mag_sq_out(mag_par), .mag_sq_valid(valid_par)
    );

    always #5 clk = ~clk;

    task push_sample;
        input signed [DATA_W-1:0] ax, ay, az;
        output [OUT_W-1:0] m_seq;
        output [OUT_W-1:0] m_par;
        reg got_seq, got_par;
        begin
            @(posedge clk);
            ax_in = ax; ay_in = ay; az_in = az;
            sample_valid = 1'b1;
            @(posedge clk);
            sample_valid = 1'b0;

            got_seq = 1'b0; got_par = 1'b0;
            m_seq = {OUT_W{1'bx}};
            m_par = {OUT_W{1'bx}};

            while (!(got_seq && got_par)) begin
                @(posedge clk);
                if (valid_seq) begin m_seq = mag_seq; got_seq = 1'b1; end
                if (valid_par) begin m_par = mag_par; got_par = 1'b1; end
            end
        end
    endtask

    reg [OUT_W-1:0] m_seq, m_par;
    reg [OUT_W-1:0] expected;

    task check;
        input [8*8-1:0] label; // 8-char label
        begin
            if (m_seq !== expected || m_par !== expected) begin
                $display("FAIL %s: expected=%0d seq=%0d par=%0d", label, expected, m_seq, m_par);
                errors = errors + 1;
            end else
                $display("PASS %s: mag_sq=%0d (seq and par agree)", label, m_seq);
        end
    endtask

    initial begin
        clk = 0; rst_n = 0; sample_valid = 0; ax_in = 0; ay_in = 0; az_in = 0;
        errors = 0;

        repeat (3) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Test 1: Ax=Ay=Az=0.5 (Q1.15=16384) -> 3 * 16384*16384 = 805,306,368
        push_sample(16'sd16384, 16'sd16384, 16'sd16384, m_seq, m_par);
        expected = 32'd805306368;
        check("T1_equal");

        // Test 2: Ax=-0.5, Ay=0.5, Az=0 -> 16384^2 + 16384^2 = 536,870,912
        push_sample(-16'sd16384, 16'sd16384, 16'sd0, m_seq, m_par);
        expected = 32'd536870912;
        check("T2_negax");

        // Test 3: all zero -> 0
        push_sample(16'sd0, 16'sd0, 16'sd0, m_seq, m_par);
        expected = 32'd0;
        check("T3_zero ");

        // Test 4: Ax = max positive (0.999969 ~ 32767), Ay=Az=0 -> 32767^2 = 1,073,676,289
        push_sample(16'sd32767, 16'sd0, 16'sd0, m_seq, m_par);
        expected = 32'd1073676289;
        check("T4_maxax");

        // Test 5: Ax = most-negative (-1.0 = -32768), Ay=Az=0 -> 32768^2 = 1,073,741,824
        push_sample(-16'sd32768, 16'sd0, 16'sd0, m_seq, m_par);
        expected = 32'd1073741824;
        check("T5_minax");

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
