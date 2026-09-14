// =============================================================================
// mac_engine.v
//
// Parameterizable multiply-accumulate (MAC) engine.
//
// Computes result = sum_{i=0}^{NUM_TAPS-1} ( a_in[i] * b_in[i] )
//
// NUM_MACS selects the degree of parallelism:
//   NUM_MACS = 1         -> fully sequential reuse of a single multiplier
//                            (Architecture A: resource-efficient)
//   NUM_MACS = NUM_TAPS  -> fully parallel, single compute cycle
//                            (Architecture B: throughput-optimized)
//   1 < NUM_MACS < NUM_TAPS, NUM_MACS divides NUM_TAPS -> intermediate point
//
// This single module implements both architectures compared in the project;
// the comparison in synthesis/implementation is obtained by instantiating it
// twice with different NUM_MACS values (see accelerator_top.v).
//
// Operand delivery: the caller presents all NUM_TAPS operands at once on
// a_in/b_in (packed, NUM_TAPS*DATA_W and NUM_TAPS*COEF_W bits respectively)
// and pulses `start`. Operands are registered internally on the start cycle,
// so the caller does not need to hold them stable beyond that cycle.
//
// Latency: GROUPS + 1 cycles from `start` to `valid`, where
// GROUPS = NUM_TAPS / NUM_MACS.
// =============================================================================

module mac_engine #(
    parameter DATA_W   = 16,   // input sample width (signed, fixed-point)
    parameter COEF_W   = 16,   // coefficient/operand-B width (signed, fixed-point)
    parameter ACC_W    = 40,   // accumulator width (must exceed DATA_W+COEF_W+log2(NUM_TAPS))
    parameter NUM_TAPS = 8,    // total number of multiply-accumulate terms
    parameter NUM_MACS = 1     // number of parallel multiplier units; must divide NUM_TAPS
)(
    input  wire                            clk,
    input  wire                            rst_n,

    input  wire                            start,   // pulse high for 1 cycle to begin
    input  wire [NUM_TAPS*DATA_W-1:0]      a_in,    // packed operand A vector
    input  wire [NUM_TAPS*COEF_W-1:0]      b_in,    // packed operand B vector

    output reg  signed [ACC_W-1:0]         result,  // sum of products
    output reg                             valid,   // 1-cycle pulse: result is valid
    output wire                            busy     // high while an operation is in flight
);

    // -------------------------------------------------------------------
    // Elaboration-time parameter check (simulation only; no synthesis effect)
    // -------------------------------------------------------------------
    // synthesis translate_off
    initial begin
        if ((NUM_TAPS % NUM_MACS) != 0) begin
            $display("ERROR: mac_engine requires NUM_MACS to divide NUM_TAPS (NUM_TAPS=%0d, NUM_MACS=%0d)",
                      NUM_TAPS, NUM_MACS);
            $finish;
        end
    end
    // synthesis translate_on

    localparam integer GROUPS = NUM_TAPS / NUM_MACS;
    localparam integer CNT_W  = (GROUPS <= 1) ? 1 : $clog2(GROUPS);

    reg [NUM_TAPS*DATA_W-1:0] a_reg;
    reg [NUM_TAPS*COEF_W-1:0] b_reg;
    reg [CNT_W-1:0]           group_cnt;
    reg                       running;

    assign busy = running;

    // ---------------------------------------------------------------
    // Combinational partial sum: NUM_MACS products for the current group
    // ---------------------------------------------------------------
    reg  signed [ACC_W-1:0]        partial_sum;
    integer                        k;
    reg  signed [DATA_W-1:0]       a_elem;
    reg  signed [COEF_W-1:0]       b_elem;
    reg  signed [DATA_W+COEF_W-1:0] prod;

    always @* begin
        partial_sum = {ACC_W{1'b0}};
        for (k = 0; k < NUM_MACS; k = k + 1) begin
            a_elem      = a_reg[(group_cnt*NUM_MACS + k)*DATA_W +: DATA_W];
            b_elem      = b_reg[(group_cnt*NUM_MACS + k)*COEF_W +: COEF_W];
            prod        = a_elem * b_elem;
            partial_sum = partial_sum + prod;
        end
    end

    // ---------------------------------------------------------------
    // Control / accumulation
    // ---------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running   <= 1'b0;
            group_cnt <= {CNT_W{1'b0}};
            result    <= {ACC_W{1'b0}};
            valid     <= 1'b0;
            a_reg     <= {NUM_TAPS*DATA_W{1'b0}};
            b_reg     <= {NUM_TAPS*COEF_W{1'b0}};
        end else begin
            valid <= 1'b0; // default: single-cycle pulse

            if (start && !running) begin
                a_reg     <= a_in;
                b_reg     <= b_in;
                group_cnt <= {CNT_W{1'b0}};
                running   <= 1'b1;
                result    <= {ACC_W{1'b0}};
            end else if (running) begin
                result <= result + partial_sum;
                if (group_cnt == GROUPS-1) begin
                    running <= 1'b0;
                    valid   <= 1'b1;
                end else begin
                    group_cnt <= group_cnt + 1'b1;
                end
            end
        end
    end

endmodule
