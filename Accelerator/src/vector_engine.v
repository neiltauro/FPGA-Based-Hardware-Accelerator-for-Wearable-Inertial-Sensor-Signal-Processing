// =============================================================================
// vector_engine.v
//
// Computes squared vector magnitude: mag_sq = Ax^2 + Ay^2 + Az^2
//
// Reuses mac_engine with NUM_TAPS = 3, feeding the same 3-axis sample as
// both operand vectors (a_in = b_in = [Ax, Ay, Az]), so the MAC engine's
// existing multiply-accumulate datapath produces the sum of squares with no
// additional arithmetic hardware. As with fir_filter, NUM_MACS is forwarded
// directly to mac_engine and selects the compared architecture:
//   NUM_MACS = 1  -> Architecture A (sequential: 3 cycles of MAC reuse)
//   NUM_MACS = 3  -> Architecture B (fully parallel: single compute cycle)
//
// No square root is computed in hardware. Where a magnitude threshold is
// needed downstream, it should be applied to mag_sq_out directly against a
// pre-squared threshold, which is the approach used throughout this project.
//
// Fixed-point convention: Ax/Ay/Az are signed Q1.(DATA_W-1) (default Q1.15).
// Each squared term is therefore Q2.(2*(DATA_W-1)) (default Q2.30), and the
// summed result is left in that format (not rescaled) since it is consumed
// as a feature value, not fed back into a further multiply-accumulate
// chain. mag_sq_out carries the lower OUT_W bits of the accumulator, which
// is sufficient for the maximum possible sum (3 * ~1.0^2 in Q2.30) given
// the default widths and is saturated defensively for any other parameter
// combination.
// =============================================================================

module vector_engine #(
    parameter DATA_W    = 16,   // per-axis sample width, signed Q1.(DATA_W-1)
    parameter ACC_W     = 40,   // internal accumulator width (mac_engine)
    parameter NUM_MACS  = 1,    // parallelism: 1 (sequential) or 3 (fully parallel)
    parameter OUT_W     = 32    // width of the magnitude-squared feature output
)(
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          sample_valid, // pulse: ax/ay/az_in are a new sample
    input  wire signed [DATA_W-1:0]      ax_in,
    input  wire signed [DATA_W-1:0]      ay_in,
    input  wire signed [DATA_W-1:0]      az_in,

    output wire                          ready,        // high when a new sample can be accepted
    output reg  [OUT_W-1:0]              mag_sq_out,   // unscaled Q2.(2*(DATA_W-1)) sum of squares
    output reg                           mag_sq_valid  // 1-cycle pulse: mag_sq_out is valid
);

    localparam NUM_TAPS = 3;

    // synthesis translate_off
    initial begin
        if ((NUM_TAPS % NUM_MACS) != 0) begin
            $display("ERROR: vector_engine requires NUM_MACS to divide 3 (got NUM_MACS=%0d)", NUM_MACS);
            $finish;
        end
    end
    // synthesis translate_on

    // ---------------------------------------------------------------
    // FSM: IDLE (latch vector) -> ISSUE (pulse mac start) -> COMPUTE (wait)
    // ---------------------------------------------------------------
    localparam S_IDLE    = 2'd0;
    localparam S_ISSUE   = 2'd1;
    localparam S_COMPUTE = 2'd2;

    reg [1:0] state;
    reg [NUM_TAPS*DATA_W-1:0] vec;

    assign ready = (state == S_IDLE);

    wire mac_start = (state == S_ISSUE);
    wire mac_valid;
    wire mac_busy;
    wire signed [ACC_W-1:0] mac_result;

    mac_engine #(
        .DATA_W(DATA_W), .COEF_W(DATA_W), .ACC_W(ACC_W),
        .NUM_TAPS(NUM_TAPS), .NUM_MACS(NUM_MACS)
    ) u_mac (
        .clk(clk), .rst_n(rst_n),
        .start(mac_start),
        .a_in(vec),
        .b_in(vec),          // same vector on both operands -> sum of squares
        .result(mac_result),
        .valid(mac_valid),
        .busy(mac_busy)
    );

    // ---------------------------------------------------------------
    // Defensive saturation to OUT_W bits (mag_sq is always non-negative)
    // ---------------------------------------------------------------
    localparam [ACC_W-1:0] OUT_MAX = (1 <<< OUT_W) - 1;

    wire [ACC_W-1:0] mac_result_u = mac_result[ACC_W-1] ? {ACC_W{1'b0}} : mac_result; // clamp any stray negative to 0
    wire [OUT_W-1:0] saturated = (mac_result_u > OUT_MAX) ? OUT_MAX[OUT_W-1:0] : mac_result_u[OUT_W-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= S_IDLE;
            vec          <= {NUM_TAPS*DATA_W{1'b0}};
            mag_sq_out   <= {OUT_W{1'b0}};
            mag_sq_valid <= 1'b0;
        end else begin
            mag_sq_valid <= 1'b0; // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    if (sample_valid) begin
                        vec   <= {az_in, ay_in, ax_in}; // packed [Ax, Ay, Az]
                        state <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    state <= S_COMPUTE;
                end

                S_COMPUTE: begin
                    if (mac_valid) begin
                        mag_sq_out   <= saturated;
                        mag_sq_valid <= 1'b1;
                        state        <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
