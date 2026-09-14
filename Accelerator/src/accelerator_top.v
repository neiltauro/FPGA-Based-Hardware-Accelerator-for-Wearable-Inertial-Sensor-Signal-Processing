// =============================================================================
// accelerator_top.v
//
// Top-level FPGA accelerator (Figure 1 / Figure 7 of the project proposal).
//
//   Input BRAM --> [FIR filter x3, one per axis] --> Vector engine --> Output BRAM
//                          ^                              ^
//                          |------------ control_fsm ------------|
//
// Processing sequence per sample:
//   1. control_fsm addresses the input BRAM and reads one packed 3-axis
//      sample {Az, Ay, Ax}.
//   2. The three axis values are wired directly (combinationally) from the
//      input BRAM's output to three identical fir_filter instances.
//   3. control_fsm pulses sample_valid to all three filters together; each
//      filter applies the same 8-tap coefficient set to its own axis.
//   4. Once all three filtered outputs are available, control_fsm forwards
//      them to vector_engine, which computes Ax'^2 + Ay'^2 + Az'^2.
//   5. The resulting feature is written to the output BRAM at the same
//      sample index.
//   6. Repeat until all NUM_SAMPLES have been processed, then pulse `done`.
//
// Architecture selection: NUM_MACS_FILT and NUM_MACS_VEC are forwarded to
// the fir_filter / vector_engine instances (and from there to mac_engine).
// Setting both to 1 realizes Architecture A (sequential, resource-
// efficient); setting NUM_MACS_FILT = TAPS and NUM_MACS_VEC = 3 realizes
// Architecture B (fully parallel, throughput-optimized). Synthesizing this
// same top-level module with each configuration is how the two
// architectures compared in the project are produced.
//
// Host interface: before asserting `start`, the host writes the input
// dataset into the input BRAM via in_wr_en/in_wr_addr/in_wr_data. After
// `done` pulses, the host reads results back via out_rd_addr/out_rd_data
// (1-cycle read latency). Both BRAM ports are time-multiplexed between the
// host and the internal datapath based on `busy`, matching the single-port
// BRAM primitives available on the target FPGA.
// =============================================================================

module accelerator_top #(
    parameter DATA_W       = 16,   // sample width, signed Q1.15
    parameter COEF_W       = 16,   // coefficient width, signed Q1.15
    parameter ACC_W        = 40,   // mac_engine accumulator width
    parameter TAPS         = 8,    // FIR filter taps
    parameter FRAC_BITS    = 15,   // Q1.15 rescale shift for the FIR filters
    parameter OUT_W        = 32,   // magnitude-squared feature width
    parameter NUM_MACS_FILT = 1,   // parallelism of each FIR filter's MAC engine
    parameter NUM_MACS_VEC  = 1,   // parallelism of the vector engine's MAC engine
    parameter NUM_SAMPLES   = 256, // dataset depth
    parameter ADDR_W        = 8,   // must satisfy 2**ADDR_W >= NUM_SAMPLES
    parameter IN_INIT_FILE  = "",  // optional $readmemh file preloading input BRAM
    parameter OUT_INIT_FILE = ""   // optional $readmemh file preloading output BRAM (normally unused)
)(
    input  wire                        clk,
    input  wire                        rst_n,

    input  wire                        start,
    output wire                        busy,
    output wire                        done,

    input  wire [TAPS*COEF_W-1:0]      coeffs_in,   // shared by all 3 axis filters

    // Host write port into the input BRAM (active only while !busy)
    input  wire                        in_wr_en,
    input  wire [ADDR_W-1:0]           in_wr_addr,
    input  wire [3*DATA_W-1:0]         in_wr_data,  // packed {Az, Ay, Ax}

    // Host read port from the output BRAM (active only while !busy)
    input  wire [ADDR_W-1:0]           out_rd_addr,
    output wire [OUT_W-1:0]            out_rd_data
);

    // =================================================================
    // Input BRAM: time-multiplexed between host writes and FSM reads
    // =================================================================
    wire [ADDR_W-1:0]   fsm_in_addr;
    wire [3*DATA_W-1:0] in_bram_dout;

    wire [ADDR_W-1:0]   in_bram_addr = busy ? fsm_in_addr : in_wr_addr;
    wire                in_bram_we   = busy ? 1'b0        : in_wr_en;
    wire [3*DATA_W-1:0] in_bram_din  = busy ? {3*DATA_W{1'b0}} : in_wr_data;

    bram_sync #(
        .WIDTH(3*DATA_W), .DEPTH(NUM_SAMPLES), .ADDR_W(ADDR_W), .INIT_FILE(IN_INIT_FILE)
    ) u_in_bram (
        .clk(clk), .we(in_bram_we), .addr(in_bram_addr),
        .din(in_bram_din), .dout(in_bram_dout)
    );

    // Axis fields extracted directly from the input BRAM's output and
    // wired straight to the three filters (no extra register stage; the
    // BRAM's own registered output already provides one cycle of latency,
    // which control_fsm's S_READ_ADDR/S_READ_WAIT states account for).
    wire signed [DATA_W-1:0] axis_ax = in_bram_dout[0*DATA_W +: DATA_W];
    wire signed [DATA_W-1:0] axis_ay = in_bram_dout[1*DATA_W +: DATA_W];
    wire signed [DATA_W-1:0] axis_az = in_bram_dout[2*DATA_W +: DATA_W];

    // =================================================================
    // Output BRAM: time-multiplexed between FSM writes and host reads
    // =================================================================
    wire [ADDR_W-1:0] fsm_out_addr;
    wire              fsm_out_we;
    wire [OUT_W-1:0]  fsm_out_data;
    wire [OUT_W-1:0]  out_bram_dout;

    wire [ADDR_W-1:0] out_bram_addr = busy ? fsm_out_addr : out_rd_addr;
    wire              out_bram_we   = busy ? fsm_out_we   : 1'b0;

    bram_sync #(
        .WIDTH(OUT_W), .DEPTH(NUM_SAMPLES), .ADDR_W(ADDR_W), .INIT_FILE(OUT_INIT_FILE)
    ) u_out_bram (
        .clk(clk), .we(out_bram_we), .addr(out_bram_addr),
        .din(fsm_out_data), .dout(out_bram_dout)
    );

    assign out_rd_data = out_bram_dout;

    // =================================================================
    // Three per-axis FIR filters, sharing one coefficient bank
    // =================================================================
    wire sample_valid_filt;

    wire ready_ax, ready_ay, ready_az;
    wire y_valid_ax, y_valid_ay, y_valid_az;
    wire signed [DATA_W-1:0] y_out_ax, y_out_ay, y_out_az;

    fir_filter #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .TAPS(TAPS), .NUM_MACS(NUM_MACS_FILT), .FRAC_BITS(FRAC_BITS)
    ) u_fir_ax (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid_filt), .x_in(axis_ax), .coeffs_in(coeffs_in),
        .ready(ready_ax), .y_out(y_out_ax), .y_valid(y_valid_ax)
    );

    fir_filter #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .TAPS(TAPS), .NUM_MACS(NUM_MACS_FILT), .FRAC_BITS(FRAC_BITS)
    ) u_fir_ay (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid_filt), .x_in(axis_ay), .coeffs_in(coeffs_in),
        .ready(ready_ay), .y_out(y_out_ay), .y_valid(y_valid_ay)
    );

    fir_filter #(
        .DATA_W(DATA_W), .COEF_W(COEF_W), .ACC_W(ACC_W),
        .TAPS(TAPS), .NUM_MACS(NUM_MACS_FILT), .FRAC_BITS(FRAC_BITS)
    ) u_fir_az (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid_filt), .x_in(axis_az), .coeffs_in(coeffs_in),
        .ready(ready_az), .y_out(y_out_az), .y_valid(y_valid_az)
    );

    // =================================================================
    // Vector engine: magnitude-squared of the filtered 3-axis sample
    // =================================================================
    wire sample_valid_vec;
    wire signed [DATA_W-1:0] vec_ax, vec_ay, vec_az;
    wire ready_vec;
    wire mag_sq_valid;
    wire [OUT_W-1:0] mag_sq_out;

    vector_engine #(
        .DATA_W(DATA_W), .ACC_W(ACC_W), .NUM_MACS(NUM_MACS_VEC), .OUT_W(OUT_W)
    ) u_vector (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid_vec),
        .ax_in(vec_ax), .ay_in(vec_ay), .az_in(vec_az),
        .ready(ready_vec), .mag_sq_out(mag_sq_out), .mag_sq_valid(mag_sq_valid)
    );

    // =================================================================
    // Control FSM
    // =================================================================
    control_fsm #(
        .DATA_W(DATA_W), .OUT_W(OUT_W), .NUM_SAMPLES(NUM_SAMPLES), .ADDR_W(ADDR_W)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),

        .in_addr(fsm_in_addr),

        .sample_valid_filt(sample_valid_filt),
        .ready_ax(ready_ax), .ready_ay(ready_ay), .ready_az(ready_az),
        .y_valid_ax(y_valid_ax), .y_valid_ay(y_valid_ay), .y_valid_az(y_valid_az),
        .y_out_ax(y_out_ax), .y_out_ay(y_out_ay), .y_out_az(y_out_az),

        .sample_valid_vec(sample_valid_vec),
        .vec_ax(vec_ax), .vec_ay(vec_ay), .vec_az(vec_az),
        .ready_vec(ready_vec), .mag_sq_valid(mag_sq_valid), .mag_sq_out(mag_sq_out),

        .out_we(fsm_out_we), .out_addr(fsm_out_addr), .out_data(fsm_out_data)
    );

endmodule
