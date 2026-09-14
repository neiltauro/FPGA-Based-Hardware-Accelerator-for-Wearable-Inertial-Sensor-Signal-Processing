// =============================================================================
// bram_sync.v
//
// Simple synchronous single-port RAM, written in the standard inference
// pattern for FPGA block RAM (registered read output, single read/write
// address port). Used for both the accelerator's input sample buffer and
// output feature buffer (Figure 1 / Figure 9 of the project proposal).
//
// Read latency: 1 cycle. dout reflects mem[addr] as of the most recent
// clock edge at which that address was presented, regardless of `we`.
// Write-first/read-first behavior is not required by this design because
// the input buffer is read-only during a run and the output buffer's
// write and host-read phases never overlap (see accelerator_top.v).
// =============================================================================

module bram_sync #(
    parameter WIDTH     = 48,
    parameter DEPTH     = 256,
    parameter ADDR_W    = 8,     // must satisfy 2**ADDR_W >= DEPTH
    parameter INIT_FILE = ""     // optional $readmemh file, simulation convenience
)(
    input  wire                  clk,
    input  wire                  we,
    input  wire [ADDR_W-1:0]     addr,
    input  wire [WIDTH-1:0]      din,
    output reg  [WIDTH-1:0]      dout
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // synthesis translate_off
    initial begin
        if (INIT_FILE != "") begin
            $readmemh(INIT_FILE, mem);
        end
    end
    // synthesis translate_on

    always @(posedge clk) begin
        if (we) begin
            mem[addr] <= din;
        end
        dout <= mem[addr];
    end

endmodule
