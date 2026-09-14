// =============================================================================
// control_fsm.v
//
// Sequences one full pass over NUM_SAMPLES input samples:
//   1. Read the next packed 3-axis sample from the input BRAM.
//   2. Dispatch it to the three per-axis FIR filters simultaneously.
//   3. Latch each filtered axis as its y_valid pulse arrives.
//   4. Once all three filtered axes are available, dispatch them to the
//      vector engine (magnitude-squared feature).
//   5. Write the resulting feature to the output BRAM at the same index.
//   6. Advance to the next sample, or assert `done` after the last one.
//
// This is the control_fsm block shown in Figure 1 / Figure 8 of the
// project proposal. It is a purely sequential, one-sample-in-flight
// controller: a new sample is only dispatched once the previous one has
// fully completed, which keeps the timing analysis of the surrounding
// pipeline simple and is sufficient for the throughput this project
// targets. (Pipelining multiple samples in flight is listed as a future
// extension, not required for the core deliverable.)
// =============================================================================

module control_fsm #(
    parameter DATA_W     = 16,
    parameter OUT_W      = 32,
    parameter NUM_SAMPLES = 256,
    parameter ADDR_W     = 8      // must satisfy 2**ADDR_W >= NUM_SAMPLES
)(
    input  wire                          clk,
    input  wire                          rst_n,

    input  wire                          start,
    output reg                           busy,   // high whenever not idle (for BRAM port muxing)
    output reg                           done,   // 1-cycle pulse when all samples are processed

    // ---------------- Input BRAM read interface ----------------
    output reg  [ADDR_W-1:0]             in_addr,

    // ---------------- FIR filter interfaces (X, Y, Z axes) -------------
    output reg                           sample_valid_filt,  // pulsed to all 3 filters together
    input  wire                          ready_ax,
    input  wire                          ready_ay,
    input  wire                          ready_az,
    input  wire                          y_valid_ax,
    input  wire                          y_valid_ay,
    input  wire                          y_valid_az,
    input  wire signed [DATA_W-1:0]      y_out_ax,
    input  wire signed [DATA_W-1:0]      y_out_ay,
    input  wire signed [DATA_W-1:0]      y_out_az,

    // ---------------- Vector engine interface ----------------
    output reg                           sample_valid_vec,
    output reg  signed [DATA_W-1:0]      vec_ax,
    output reg  signed [DATA_W-1:0]      vec_ay,
    output reg  signed [DATA_W-1:0]      vec_az,
    input  wire                          ready_vec,
    input  wire                          mag_sq_valid,
    input  wire [OUT_W-1:0]              mag_sq_out,

    // ---------------- Output BRAM write interface ----------------
    output reg                           out_we,
    output reg  [ADDR_W-1:0]             out_addr,
    output reg  [OUT_W-1:0]              out_data
);

    // Note: the packed input sample is read directly from the input BRAM
    // by accelerator_top and wired straight to the three fir_filter
    // instances; this FSM only needs to generate the shared address and
    // the timing pulses, not the sample data itself.

    localparam S_IDLE          = 4'd0;
    localparam S_READ_ADDR     = 4'd1;
    localparam S_READ_WAIT     = 4'd2;
    localparam S_DISPATCH_FILT = 4'd3;
    localparam S_WAIT_FILT     = 4'd4;
    localparam S_DISPATCH_VEC  = 4'd5;
    localparam S_WAIT_VEC      = 4'd6;
    localparam S_NEXT          = 4'd7;
    localparam S_DONE          = 4'd8;

    reg [3:0]        state;
    reg [ADDR_W-1:0] sample_idx;
    reg              got_ax, got_ay, got_az;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state             <= S_IDLE;
            busy              <= 1'b0;
            done              <= 1'b0;
            in_addr           <= {ADDR_W{1'b0}};
            sample_idx        <= {ADDR_W{1'b0}};
            sample_valid_filt <= 1'b0;
            sample_valid_vec  <= 1'b0;
            out_we            <= 1'b0;
            out_addr          <= {ADDR_W{1'b0}};
            out_data          <= {OUT_W{1'b0}};
            vec_ax            <= {DATA_W{1'b0}};
            vec_ay            <= {DATA_W{1'b0}};
            vec_az            <= {DATA_W{1'b0}};
            got_ax            <= 1'b0;
            got_ay            <= 1'b0;
            got_az            <= 1'b0;
        end else begin
            // defaults: single-cycle pulses unless overridden below
            sample_valid_filt <= 1'b0;
            sample_valid_vec  <= 1'b0;
            out_we            <= 1'b0;
            done              <= 1'b0;

            case (state)
                // -------------------------------------------------
                S_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        sample_idx <= {ADDR_W{1'b0}};
                        in_addr    <= {ADDR_W{1'b0}};
                        busy       <= 1'b1;
                        state      <= S_READ_ADDR;
                    end
                end

                // -------------------------------------------------
                S_READ_ADDR: begin
                    // in_addr has been stable since the previous cycle;
                    // this cycle lets the BRAM see it for a full period.
                    state <= S_READ_WAIT;
                end

                S_READ_WAIT: begin
                    // in_data is now valid (BRAM registered it on the
                    // edge that closed S_READ_ADDR).
                    state <= S_DISPATCH_FILT;
                end

                // -------------------------------------------------
                S_DISPATCH_FILT: begin
                    // synthesis translate_off
                    if (!(ready_ax && ready_ay && ready_az)) begin
                        $display("WARNING: control_fsm dispatched to a busy filter at t=%0t", $time);
                    end
                    // synthesis translate_on
                    sample_valid_filt <= 1'b1;
                    got_ax <= 1'b0;
                    got_ay <= 1'b0;
                    got_az <= 1'b0;
                    state  <= S_WAIT_FILT;
                end

                S_WAIT_FILT: begin
                    if (y_valid_ax) begin vec_ax <= y_out_ax; got_ax <= 1'b1; end
                    if (y_valid_ay) begin vec_ay <= y_out_ay; got_ay <= 1'b1; end
                    if (y_valid_az) begin vec_az <= y_out_az; got_az <= 1'b1; end

                    if ((got_ax || y_valid_ax) &&
                        (got_ay || y_valid_ay) &&
                        (got_az || y_valid_az)) begin
                        state <= S_DISPATCH_VEC;
                    end
                end

                // -------------------------------------------------
                S_DISPATCH_VEC: begin
                    // synthesis translate_off
                    if (!ready_vec) begin
                        $display("WARNING: control_fsm dispatched to a busy vector engine at t=%0t", $time);
                    end
                    // synthesis translate_on
                    sample_valid_vec <= 1'b1;
                    state <= S_WAIT_VEC;
                end

                S_WAIT_VEC: begin
                    if (mag_sq_valid) begin
                        out_data <= mag_sq_out;
                        out_addr <= sample_idx;
                        out_we   <= 1'b1;
                        state    <= S_NEXT;
                    end
                end

                // -------------------------------------------------
                S_NEXT: begin
                    if (sample_idx == NUM_SAMPLES-1) begin
                        state <= S_DONE;
                    end else begin
                        sample_idx <= sample_idx + 1'b1;
                        in_addr    <= sample_idx + 1'b1;
                        state      <= S_READ_ADDR;
                    end
                end

                S_DONE: begin
                    done  <= 1'b1;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
