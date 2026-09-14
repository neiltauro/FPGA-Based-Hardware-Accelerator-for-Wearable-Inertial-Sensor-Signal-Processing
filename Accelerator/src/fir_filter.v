// =============================================================================
// fir_filter.v
//
// Streaming FIR filter: y[n] = sum_{i=0}^{TAPS-1} h_i * x[n-i]
//
// Wraps mac_engine with a tapped delay line (shift register) of input
// samples. NUM_MACS is forwarded directly to mac_engine, so this same
// fir_filter module implements both compared architectures:
//   NUM_MACS = 1     -> Architecture A (sequential MAC reuse)
//   NUM_MACS = TAPS  -> Architecture B (fully parallel MAC array)
//
// Fixed-point convention: samples and coefficients are signed Q(1.FRAC_BITS)
// fixed-point (default Q1.15, 16-bit). Each product is therefore Q2.30; the
// accumulated sum is rescaled back to Q1.15 by an arithmetic right shift of
// FRAC_BITS, then saturated to the DATA_W-bit output range.
//
// Coefficients (coeffs_in) are supplied continuously by the caller (e.g. a
// coefficient ROM/register bank in accelerator_top) and must remain stable
// for the duration of a filter operation (from sample_valid until y_valid).
//
// Throughput: one output sample every (TAPS/NUM_MACS + 3) cycles, matching
// the mac_engine latency plus one cycle each for the shift and issue stages.
// =============================================================================

module fir_filter #(
    parameter DATA_W    = 16,   // sample width, signed Q1.(DATA_W-1)
    parameter COEF_W    = 16,   // coefficient width, signed Q1.(COEF_W-1)
    parameter ACC_W     = 40,   // internal accumulator width (mac_engine)
    parameter TAPS      = 8,    // number of filter taps
    parameter NUM_MACS  = 1,    // parallelism: 1 = sequential, TAPS = fully parallel
    parameter FRAC_BITS = 15    // fractional bits for Q1.15 rescale after multiply
)(
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          sample_valid, // pulse: x_in is a new sample
    input  wire signed [DATA_W-1:0]      x_in,
    input  wire [TAPS*COEF_W-1:0]        coeffs_in,    // packed h[0..TAPS-1]

    output wire                          ready,        // high when a new sample can be accepted
    output reg  signed [DATA_W-1:0]      y_out,
    output reg                           y_valid       // 1-cycle pulse: y_out is valid
);

    // ---------------------------------------------------------------
    // Tapped delay line: window[0] = x[n] (newest) .. window[TAPS-1] = x[n-(TAPS-1)]
    // ---------------------------------------------------------------
    reg [TAPS*DATA_W-1:0] window;

    // ---------------------------------------------------------------
    // FSM: IDLE (accept sample) -> ISSUE (pulse mac start) -> COMPUTE (wait)
    // ---------------------------------------------------------------
    localparam S_IDLE    = 2'd0;
    localparam S_ISSUE   = 2'd1;
    localparam S_COMPUTE = 2'd2;

    reg [1:0] state;

    assign ready = (state == S_IDLE);

    wire mac_start = (state == S_ISSUE);
    wire mac_valid;
    wire mac_busy;
    wire signed [ACC_W-1:0] mac_result;

    mac_engine #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .NUM_TAPS(TAPS), .NUM_MACS(NUM_MACS)
    ) u_mac (
        .clk(clk), .rst_n(rst_n),
        .start(mac_start),
        .a_in(window),
        .b_in(coeffs_in),
        .result(mac_result),
        .valid(mac_valid),
        .busy(mac_busy)
    );

    // ---------------------------------------------------------------
    // Rescale Q2.(2*FRAC_BITS) accumulator result back to Q1.FRAC_BITS,
    // with saturation to the DATA_W-bit signed output range.
    // ---------------------------------------------------------------
    localparam signed [ACC_W-1:0] OUT_MAX = (1 <<< (DATA_W-1)) - 1;
    localparam signed [ACC_W-1:0] OUT_MIN = -(1 <<< (DATA_W-1));

    wire signed [ACC_W-1:0] rescaled = mac_result >>> FRAC_BITS;
    wire signed [DATA_W-1:0] saturated =
        (rescaled > OUT_MAX) ? OUT_MAX[DATA_W-1:0] :
        (rescaled < OUT_MIN) ? OUT_MIN[DATA_W-1:0] :
                                rescaled[DATA_W-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state  <= S_IDLE;
            window <= {TAPS*DATA_W{1'b0}};
            y_out  <= {DATA_W{1'b0}};
            y_valid <= 1'b0;
        end else begin
            y_valid <= 1'b0; // default: single-cycle pulse

            case (state)
                S_IDLE: begin
                    if (sample_valid) begin
                        // shift in newest sample, discard oldest
                        window <= {window[(TAPS-1)*DATA_W-1:0], x_in};
                        state  <= S_ISSUE;
                    end
                end

                S_ISSUE: begin
                    state <= S_COMPUTE;
                end

                S_COMPUTE: begin
                    if (mac_valid) begin
                        y_out   <= saturated;
                        y_valid <= 1'b1;
                        state   <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
