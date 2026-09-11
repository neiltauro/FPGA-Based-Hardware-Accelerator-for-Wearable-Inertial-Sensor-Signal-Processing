# FPGA Accelerator for Wearable Inertial Sensor Signal Processing

## 1. Project Overview

Wearable inertial measurement units (IMUs) generate continuous streams of
tri-axial accelerometer data that are commonly used for applications such as
activity recognition, gait analysis, motion tracking, and wearable sensing.

However, raw IMU data typically contains sensor noise and produces a large
amount of data that must be processed before it can be used effectively.
Common operations such as digital filtering, multiply-accumulate (MAC)
operations, and feature extraction are computationally intensive when
performed continuously on a general-purpose processor.

This project aims to develop a **parameterizable FPGA-based hardware
accelerator** for a representative wearable inertial-sensor signal-processing
pipeline.

The accelerator will process three-axis accelerometer data:

```text
Ax ─┐
Ay ─┼──> FIR Filtering ──> Feature Extraction ──> Output Feature
Az ─┘
```

The primary processing stages are:

1. An 8-tap FIR low-pass filter applied independently to each accelerometer
   axis.
2. Squared vector-magnitude calculation using the filtered X, Y, and Z
   components.
3. Storage of the resulting feature values for subsequent analysis or
   readback.

The design is parameterizable so that different hardware architectures can
be evaluated without changing the overall processing algorithm.

Two implementations are considered:

- **Sequential architecture:** A single MAC unit is reused across multiple
  clock cycles.
- **Parallel architecture:** Multiple MAC units operate concurrently to
  reduce processing latency.

The primary objective is to understand the trade-off between **performance,
latency, throughput, and FPGA resource utilization** when implementing
signal-processing algorithms in dedicated hardware.

---

## 2. Project Goal

The main goal of this project is to design, implement, and evaluate an FPGA
hardware accelerator capable of processing wearable inertial sensor data
using a fixed-point signal-processing pipeline.

The accelerator is intended to demonstrate how computationally intensive
operations can be mapped from software into dedicated FPGA hardware.

The project specifically aims to:

- Process real or representative tri-axial accelerometer data.
- Perform digital low-pass filtering directly in FPGA hardware.
- Implement multiply-accumulate operations using a reusable hardware engine.
- Extract a representative motion-related feature from the filtered data.
- Support both sequential and parallel hardware architectures.
- Compare the performance and resource requirements of the two architectures.
- Use fixed-point arithmetic suitable for FPGA implementation.
- Validate FPGA results against a Python software reference model.
- Integrate the accelerator with a Xilinx Artix-7 FPGA platform.
- Provide a mechanism for loading input data into FPGA memory.
- Provide a mechanism for retrieving and inspecting processed results.

The project is therefore not only focused on implementing the signal-processing
algorithm, but also on understanding the complete path from:

```text
Sensor Data
     │
     ▼
Software Preprocessing
     │
     ▼
Fixed-Point Input Data
     │
     ▼
FPGA Memory
     │
     ▼
Hardware Accelerator
     │
     ▼
Processed Feature Data
     │
     ▼
FPGA Readback / Analysis
```

---

## 3. Overall Signal-Processing Pipeline

The accelerator processes each accelerometer sample through a sequence of
hardware operations.

Each input sample contains three acceleration components:

```text
Input Sample

        ┌─────────────┐
        │ Accelerometer│
        │    Data      │
        └──────┬──────┘
               │
       ┌───────┼───────┐
       │       │       │
       ▼       ▼       ▼
      Ax      Ay      Az
       │       │       │
       ▼       ▼       ▼
   FIR Filter FIR Filter FIR Filter
       │       │       │
       ▼       ▼       ▼
      Ax'     Ay'     Az'
       │       │       │
       └───────┼───────┘
               │
               ▼
       Vector Feature Engine
               │
               ▼
        Ax'² + Ay'² + Az'²
               │
               ▼
          Output BRAM
```

The filtered signals are represented as:

```text
Ax' = FIR(Ax)
Ay' = FIR(Ay)
Az' = FIR(Az)
```

The extracted feature is the squared vector magnitude:

```text
Magnitude² = Ax'² + Ay'² + Az'²
```

The square root is intentionally not required because the squared magnitude
is sufficient as a representative motion-intensity feature and avoids the
additional hardware cost of implementing a square-root operation.

---

## 4. Input Data and Software Preprocessing

The FPGA accelerator operates on fixed-point input data rather than directly
processing floating-point sensor values.

A Python preprocessing stage is used to prepare the input data before it is
loaded into FPGA memory.

The preprocessing flow is:

```text
Raw / Recorded IMU Data
          │
          ▼
     Python Script
          │
          ├── Select Ax, Ay, Az
          │
          ├── Apply scaling
          │
          ├── Convert to fixed-point
          │
          └── Generate FPGA memory data
          │
          ▼
     Input .mem Data
          │
          ▼
       FPGA BRAM
```

The Python model also acts as the software reference model for validating the
hardware implementation.

This allows the same input dataset to be processed by both:

```text
Python Reference Model ─────┐
                            ├──> Compare Results
FPGA RTL Accelerator ───────┘
```

The comparison is performed using fixed-point values so that the software and
hardware implementations can be compared at the same numerical precision.

---

## 5. Fixed-Point Arithmetic

The accelerator uses **Q1.15 fixed-point representation** for the primary
signal-processing data.

The Q1.15 format provides:

- 1 sign/integer bit
- 15 fractional bits
- 16-bit total representation

The conversion from a normalized floating-point value to Q1.15 can be
represented as:

```text
fixed_value = round(float_value × 2^15)
```

The hardware then operates directly on the resulting integer values.

For example, an input value represented in software as:

```text
x = 0.5
```

would be represented approximately as:

```text
0.5 × 32768 = 16384
```

and stored as the corresponding signed fixed-point integer.

Using fixed-point arithmetic provides a predictable hardware implementation
and avoids requiring floating-point arithmetic resources for the core
accelerator datapath.

The Python reference model uses the same fixed-point representation and
arithmetic rules so that hardware results can be compared against software
results.

---

# 6. FIR Filtering

## 6.1 Purpose of the FIR Filter

The accelerometer signals can contain high-frequency noise and other
components that are not required for the representative motion-processing
pipeline.

An FIR low-pass filter is therefore applied independently to each axis.

The design uses an **8-tap FIR filter**.

The three filtering paths are:

```text
Ax ──> FIR X ──> Ax'

Ay ──> FIR Y ──> Ay'

Az ──> FIR Z ──> Az'
```

Each filter uses the same underlying hardware architecture.

Only the input sample stream and corresponding filter history are different
for each axis.

---

## 6.2 FIR Equation

For an 8-tap FIR filter, the output can be expressed as:

```text
y[n] = h[0]x[n]
     + h[1]x[n-1]
     + h[2]x[n-2]
     + h[3]x[n-3]
     + h[4]x[n-4]
     + h[5]x[n-5]
     + h[6]x[n-6]
     + h[7]x[n-7]
```

where:

- `x[n]` is the current input sample.
- `x[n-k]` represents previous samples.
- `h[k]` represents the FIR filter coefficient.
- `y[n]` is the filtered output.

The FIR therefore requires eight multiplication operations and the
corresponding accumulation of the products.

The fundamental computation is:

```text
             7
y[n] = Σ h[k] × x[n-k]
             k=0
```

This naturally maps to a multiply-accumulate architecture.

---

## 6.3 FIR Coefficient Generation

The filter coefficients are generated using Python.

The design uses a low-pass FIR filter with an 8-tap configuration and a
Hamming-window-based coefficient generation approach.

The representative filter configuration uses:

```text
Number of taps : 8
Filter type    : Low-pass FIR
Window         : Hamming
Sample rate    : 100 Hz
Cutoff         : 10 Hz
```

The coefficients generated by Python are converted into the same fixed-point
representation used by the hardware.

This ensures that the FPGA and Python implementations operate using the same
coefficient values.

---

# 7. Parameterizable MAC Engine

A central component of the accelerator is a reusable **MAC engine**.

MAC stands for:

```text
Multiply-Accumulate
```

The basic operation is:

```text
accumulator = accumulator + (input × coefficient)
```

For the FIR filter, the MAC operation is repeated for each tap.

The MAC engine is designed to be parameterizable so that the same underlying
hardware can support different levels of parallelism.

The architecture is controlled primarily through the number of MAC units:

```text
NUM_MACS = 1
```

for the sequential implementation, and:

```text
NUM_MACS = 8
```

for the fully parallel 8-tap FIR implementation.

The same concept is also used by the vector feature engine.

---

## 7.1 Sequential MAC Architecture

In the sequential architecture, one MAC unit is reused for all operations.

For an 8-tap FIR filter:

```text
Cycle 1: MAC tap 0
Cycle 2: MAC tap 1
Cycle 3: MAC tap 2
Cycle 4: MAC tap 3
Cycle 5: MAC tap 4
Cycle 6: MAC tap 5
Cycle 7: MAC tap 6
Cycle 8: MAC tap 7
```

Conceptually:

```text
              ┌──────────────┐
Input ───────>│              │
Coefficient ->│   MAC Unit   │───> Accumulator
              │              │
              └──────────────┘
                     ▲
                     │
               Control FSM
```

The same physical MAC hardware is reused across all eight operations.

### Advantages

- Lower hardware resource usage.
- Fewer multipliers/DSP resources required.
- Smaller implementation footprint.

### Disadvantages

- Higher latency.
- More clock cycles are required for each FIR calculation.
- Lower throughput when processing individual samples.

---

## 7.2 Parallel MAC Architecture

In the parallel architecture, multiple MAC operations are performed
concurrently.

For an 8-tap FIR filter:

```text
             ┌─────────┐
x[n]        ─>│  MAC 0  │─┐
x[n-1]      ─>│  MAC 1  │─┤
x[n-2]      ─>│  MAC 2  │─┤
x[n-3]      ─>│  MAC 3  │─┤
x[n-4]      ─>│  MAC 4  │─┤
x[n-5]      ─>│  MAC 5  │─┤
x[n-6]      ─>│  MAC 6  │─┤
x[n-7]      ─>│  MAC 7  │─┤
             └─────────┘ │
                          ▼
                     Accumulation
                          │
                          ▼
                       FIR Out
```

All eight products can be generated concurrently and then accumulated.

### Advantages

- Significantly lower processing latency.
- Higher potential throughput.
- More suitable for high-performance streaming implementations.

### Disadvantages

- Requires more multiplier/DSP resources.
- Uses more FPGA logic.
- Can increase routing and timing complexity.

---

## 7.3 Parameterized Architecture

The goal of the MAC engine is to avoid implementing separate hardware
architectures for every possible configuration.

Instead, the same module can be parameterized:

```text
NUM_MACS = 1
```

for sequential processing and:

```text
NUM_MACS = 8
```

for parallel FIR processing.

The architecture therefore becomes:

```text
                 Parameter
                    │
                    ▼
               NUM_MACS
                    │
          ┌─────────┴─────────┐
          │                   │
          ▼                   ▼
     NUM_MACS = 1        NUM_MACS = 8
          │                   │
          ▼                   ▼
     Sequential            Parallel
      Hardware              Hardware
```

This allows the project to compare different hardware implementation
strategies while maintaining the same high-level algorithm.

---

# 8. Vector Feature Extraction

After filtering, the three acceleration components are combined to generate
a representative motion feature.

The feature is the squared vector magnitude:

```text
M² = Ax'² + Ay'² + Az'²
```

The processing flow is:

```text
             Ax'
              │
              ▼
            Ax'²
              │
              │
Ay' ──────────┼─────────┐
 │            │         │
 ▼            │         │
Ay'²          │         │
 │            │         │
 │            ▼         │
 │          SUM <───────┘
 │            ▲
 │            │
Az' ──────────┘
 │
 ▼
Az'²
```

A simpler representation is:

```text
Ax' ──> Square ──┐
                  │
Ay' ──> Square ──┼──> Adder ──> M²
                  │
Az' ──> Square ──┘
```

The vector engine therefore requires three multiplication operations followed
by accumulation.

---

## 8.1 Vector Engine Architecture

The same parameterizable MAC concept is used for vector feature extraction.

For a sequential implementation:

```text
NUM_MACS = 1
```

and the three squared terms are calculated over multiple cycles.

For a parallel implementation:

```text
NUM_MACS = 3
```

allowing the three squared terms to be calculated concurrently.

Conceptually:

```text
Sequential:

Ax'² ──┐
       │
Ay'² ──┼──> Single MAC / Accumulator
       │
Az'² ──┘
```

and:

```text
Parallel:

Ax' ──> MAC 0 ──┐
Ay' ──> MAC 1 ──┼──> Accumulation ──> M²
Az' ──> MAC 2 ──┘
```

This provides another example of the performance-versus-resource trade-off
being investigated in the project.

---

# 9. Complete Accelerator Datapath

The complete hardware architecture can be represented as:

```text
                         FPGA
 ┌───────────────────────────────────────────────────────────────┐
 │                                                               │
 │                       Input BRAM                              │
 │                           │                                   │
 │                           ▼                                   │
 │                    ┌──────────────┐                           │
 │                    │ Control FSM  │                           │
 │                    └──────┬───────┘                           │
 │                           │                                   │
 │                 ┌─────────┼─────────┐                         │
 │                 │         │         │                         │
 │                 ▼         ▼         ▼                         │
 │              FIR X     FIR Y     FIR Z                        │
 │                 │         │         │                         │
 │                 ▼         ▼         ▼                         │
 │                Ax'       Ay'       Az'                         │
 │                 │         │         │                         │
 │                 └─────────┼─────────┘                         │
 │                           │                                   │
 │                           ▼                                   │
 │                  Vector Feature Engine                        │
 │                           │                                   │
 │                           ▼                                   │
 │                       M² Result                               │
 │                           │                                   │
 │                           ▼                                   │
 │                       Output BRAM                             │
 │                                                               │
 └───────────────────────────────────────────────────────────────┘
```

The major hardware blocks are therefore:

1. Input BRAM
2. Control FSM
3. FIR X
4. FIR Y
5. FIR Z
6. Vector feature engine
7. Output BRAM

The FIR filters and vector feature engine are built around the reusable
parameterizable MAC architecture.

---

# 10. Control FSM

The control FSM coordinates the movement of data through the accelerator.

The accelerator processes one input sample at a time.

A conceptual control sequence is:

```text
             ┌─────────┐
             │  IDLE   │
             └────┬────┘
                  │ Start
                  ▼
          ┌───────────────┐
          │ READ SAMPLE   │
          └───────┬───────┘
                  │
                  ▼
          ┌───────────────┐
          │ DISPATCH FIR  │
          │   X/Y/Z       │
          └───────┬───────┘
                  │
                  ▼
          ┌───────────────┐
          │  WAIT FOR FIR │
          │    RESULTS    │
          └───────┬───────┘
                  │
                  ▼
          ┌───────────────┐
          │ VECTOR ENGINE │
          └───────┬───────┘
                  │
                  ▼
          ┌───────────────┐
          │ WRITE RESULT  │
          └───────┬───────┘
                  │
                  ▼
             More Samples?
              /       \
            Yes        No
             │          │
             │          ▼
             │       ┌──────┐
             │       │ DONE │
             │       └──────┘
             │
             └────> READ SAMPLE
```

The FSM is responsible for:

- Starting a processing operation.
- Reading the current sample from input memory.
- Providing the X, Y, and Z samples to their FIR filters.
- Waiting for the FIR operations to complete.
- Sending the filtered values to the vector engine.
- Waiting for feature extraction to complete.
- Writing the resulting feature into output memory.
- Incrementing the sample index.
- Detecting when all samples have been processed.
- Indicating completion.

The exact number of cycles spent in the processing states depends on whether
the sequential or parallel architecture is selected.

---

# 11. FPGA Memory Architecture

The accelerator uses on-chip FPGA memory to store input and output data.

The basic memory organization is:

```text
                 FPGA
                  │
        ┌─────────┴─────────┐
        │                   │
        ▼                   ▼
   Input BRAM           Output BRAM
        │                   ▲
        │                   │
        ▼                   │
   Accelerator ─────────────┘
```

## Input BRAM

Input BRAM contains the fixed-point accelerometer samples.

Conceptually, the input memory stores:

```text
Address       Data
-------       ----------------
0             Ax[0], Ay[0], Az[0]
1             Ax[1], Ay[1], Az[1]
2             Ax[2], Ay[2], Az[2]
...
N-1           Ax[N-1], Ay[N-1], Az[N-1]
```

The exact memory packing can be selected during FPGA integration.

The important requirement is that the accelerator can retrieve the X, Y, and
Z components associated with each sample.

## Output BRAM

Output BRAM stores the feature produced for each input sample:

```text
Address       Output
-------       ----------------
0             M²[0]
1             M²[1]
2             M²[2]
...
N-1           M²[N-1]
```

This allows the processed data to remain available for subsequent readback
and analysis.

---

# 12. FPGA Integration Plan

The accelerator is intended to be integrated onto a **Digilent Nexys A7-100T**
development board using the Xilinx Artix-7 FPGA.

The target FPGA is:

```text
Device: xc7a100tcsg324-1
Family: Xilinx Artix-7
```

The FPGA integration is intended to demonstrate that the RTL accelerator can
operate as an actual hardware system rather than only as a simulation model.

The planned integration flow is:

```text
Python Data Preparation
          │
          ▼
       .mem File
          │
          ▼
      Input BRAM
          │
          ▼
    FPGA Accelerator
          │
          ▼
      Output BRAM
          │
          ▼
   FPGA Readback / Debug
```

---

# 13. Loading Input Data into the FPGA

One of the first FPGA integration steps is to preload the input accelerometer
data into on-chip memory.

A practical initial approach is to use a memory initialization file:

```text
$readmemh(...)
```

The memory initialization file contains the fixed-point representation of the
accelerometer dataset.

The FPGA synthesis/implementation flow can then initialize the BRAM with the
known test data.

The initial system therefore does not require a physical IMU sensor to be
connected to the FPGA.

Instead:

```text
Recorded IMU Data
       │
       ▼
Python Preprocessing
       │
       ▼
Hex / Memory Initialization File
       │
       ▼
FPGA BRAM
```

This makes the first hardware bring-up deterministic and repeatable.

---

# 14. FPGA Start and Control

A simple board-level control mechanism can be used for the first hardware
integration.

For example:

```text
Push Button
     │
     ▼
 Start Signal
     │
     ▼
 Control FSM
```

The accelerator can expose basic control/status signals such as:

```text
start
busy
done
```

These can initially be connected to board-level I/O for easy observation.

For example:

```text
Button ──> start

busy ────> LED

done ────> LED
```

This provides a simple way to verify that the accelerator starts, processes
the dataset, and reaches its completion state.

---

# 15. FPGA Bring-Up

The FPGA bring-up will proceed incrementally rather than attempting to
debug the complete system at once.

A conceptual sequence is:

### Step 1: Verify Clock

Confirm that the FPGA clock is operating at the intended frequency.

```text
Board Clock
     │
     ▼
Clock Input
     │
     ▼
Accelerator Clock
```

### Step 2: Verify Input BRAM

Confirm that the expected fixed-point input values are correctly initialized
and accessible.

### Step 3: Verify Control FSM

Check that the FSM transitions correctly through:

```text
IDLE
  ↓
READ
  ↓
FIR
  ↓
VECTOR
  ↓
WRITE
  ↓
NEXT / DONE
```

### Step 4: Verify FIR Processing

Check the filtered X, Y, and Z values.

### Step 5: Verify Vector Feature

Check:

```text
M² = Ax'² + Ay'² + Az'²
```

### Step 6: Verify Output BRAM

Confirm that the expected feature values are written to the correct memory
addresses.

### Step 7: Verify End-to-End Processing

Finally, compare the complete FPGA output dataset against the Python
reference results.

---

# 16. FPGA Readback and Debugging

After processing, the output data needs to be retrieved from the FPGA for
comparison with the software reference model.

Possible debugging and readback approaches include:

- Integrated Logic Analyzer (ILA)
- JTAG-based access
- JTAG-to-AXI infrastructure
- UART-based output
- Other FPGA communication interfaces

The initial implementation can use ILA to observe internal signals.

Important signals to monitor include:

```text
start
busy
done
sample_index

input Ax
input Ay
input Az

filtered Ax'
filtered Ay'
filtered Az'

vector result

input BRAM address
output BRAM address
```

This allows the internal operation of the accelerator to be observed directly
inside the FPGA.

A simplified debug path is:

```text
                     FPGA
                      │
          ┌───────────┴───────────┐
          │                       │
          ▼                       ▼
    Accelerator                ILA
          │                       │
          │                 Internal Signals
          │                       │
          ▼                       ▼
     Output BRAM              Debug View
```

For larger datasets, a more practical readback mechanism can be used to
transfer the output BRAM contents to a host computer.

---

# 17. Python Software Reference Model

The Python implementation serves two important purposes:

1. Preparing input data for the FPGA.
2. Providing an independent reference against which the hardware can be
   compared.

The reference model follows the same algorithm as the RTL implementation.

The software processing chain is:

```text
Input Accelerometer Data
          │
          ▼
     Fixed-Point
     Conversion
          │
          ▼
      FIR Filter
      X / Y / Z
          │
          ▼
  Squared Magnitude
          │
          ▼
     Reference Output
```

The reference model should perform the calculations using the same fixed-point
format as the FPGA implementation.

This is important because comparing a fixed-point FPGA result directly against
an unrestricted floating-point result can introduce numerical differences
that are unrelated to hardware correctness.

The desired comparison is therefore:

```text
Python Fixed-Point Result
           │
           │
           ├──────────────┐
           │              │
           ▼              ▼
       Expected        FPGA Result
           │              │
           └──────┬───────┘
                  ▼
              Compare
```

For a correctly implemented accelerator, the expected and hardware results
should match according to the defined fixed-point arithmetic and any
intentional truncation or rounding behavior.

---

# 18. RTL Verification Strategy

Before FPGA deployment, the accelerator is verified using RTL simulation.

The verification process follows a software-versus-hardware comparison model.

```text
                Same Input Dataset
                       │
             ┌─────────┴─────────┐
             │                   │
             ▼                   ▼
      Python Reference       RTL Simulation
             │                   │
             ▼                   ▼
       Expected Data        Hardware Data
             │                   │
             └─────────┬─────────┘
                       ▼
                  Comparison
```

The verification should cover:

- Input data loading.
- FIR filter operation.
- MAC accumulation.
- Sequential MAC operation.
- Parallel MAC operation.
- Vector feature calculation.
- Control FSM transitions.
- Memory addressing.
- Output generation.
- Completion signaling.

The same test vectors can be used to validate both architectures.

This ensures that the sequential and parallel implementations produce the
same algorithmic results even though their internal timing and resource usage
are different.

---

# 19. Sequential vs Parallel Architecture

A major purpose of the project is to evaluate the trade-off between hardware
resource usage and processing performance.

The two primary architectures are:

```text
                 Hardware Architecture
                         │
              ┌──────────┴──────────┐
              │                     │
              ▼                     ▼
         Sequential             Parallel
         NUM_MACS=1             NUM_MACS=8
              │                     │
              ▼                     ▼
        Low Resources          High Resources
        High Latency           Low Latency
```

## Sequential Architecture

The sequential architecture reuses a single MAC unit.

```text
8 operations
     │
     ▼
1 MAC
     │
     ▼
Multiple clock cycles
```

This minimizes hardware resources but increases latency.

## Parallel Architecture

The parallel architecture uses multiple MAC units.

```text
8 operations
     │
     ▼
8 MACs
     │
     ▼
Fewer clock cycles
```

This reduces latency but requires more FPGA resources.

---

# 20. Architecture Evaluation

The two architectures will be compared using several hardware metrics.

## Latency

Latency is the number of clock cycles required to process an input sample.

For example:

```text
Sequential:
More clock cycles per sample

Parallel:
Fewer clock cycles per sample
```

The exact latency depends on the implementation and control structure.

## Throughput

Throughput represents how many samples can be processed per unit time.

A highly parallel architecture has the potential for higher throughput because
more arithmetic operations can be performed concurrently.

## FPGA Resource Utilization

The implementation will be evaluated based on FPGA resources such as:

- LUTs
- Flip-Flops
- DSP slices
- BRAM
- Other implementation resources as appropriate

The expected trade-off is:

```text
                    Resource Usage
                         ▲
                         │
                         │       Parallel
                         │          ●
                         │
                         │
                         │
                         │  Sequential
                         │      ●
                         └──────────────────> Performance
```

The parallel architecture is expected to consume more arithmetic resources,
while the sequential architecture is expected to use fewer resources.

## Timing

The synthesized designs will also be evaluated using FPGA timing metrics.

Important measurements include:

- Maximum achievable clock frequency.
- Setup timing.
- Hold timing.
- Worst negative slack where applicable.

The goal is to determine whether each architecture can meet the desired
clock-frequency target.

---

# 21. FPGA Implementation Metrics

After synthesis and implementation, the architectures can be compared using
a table similar to:

| Metric | Sequential | Parallel |
|---|---:|---:|
| MAC Units | 1 | 8 |
| FIR Latency | Higher | Lower |
| Throughput | Lower | Higher |
| LUT Usage | Lower | Higher |
| FF Usage | Lower | Higher |
| DSP Usage | Lower | Higher |
| BRAM Usage | Similar | Similar |
| Maximum Frequency | To be measured | To be measured |

The actual FPGA resource and timing values will come from the Vivado
synthesis and implementation reports.

---

# 22. End-to-End System

The complete intended system can be viewed as three major layers.

## Software Layer

```text
Recorded / Generated IMU Data
             │
             ▼
       Python Processing
             │
             ├── Filtering Reference
             ├── Fixed-Point Conversion
             └── Memory File Generation
```

## FPGA Hardware Layer

```text
              Input BRAM
                  │
                  ▼
            Control FSM
                  │
        ┌─────────┼─────────┐
        ▼         ▼         ▼
      FIR X     FIR Y     FIR Z
        │         │         │
        └─────────┼─────────┘
                  ▼
          Vector Feature
             Engine
                  │
                  ▼
             Output BRAM
```

## Host / Debug Layer

```text
             FPGA
              │
              ▼
        Output Readback
              │
              ▼
        Host Computer
              │
              ▼
       Python Comparison
```

The complete flow is therefore:

```text
IMU Dataset
    │
    ▼
Python Preprocessing
    │
    ▼
Fixed-Point Memory File
    │
    ▼
FPGA Input BRAM
    │
    ▼
FIR Filtering
    │
    ▼
Vector Feature Extraction
    │
    ▼
Output BRAM
    │
    ▼
FPGA Readback
    │
    ▼
Python Reference Comparison
```

---

# 23. Design Philosophy

The accelerator is intentionally designed around a small number of reusable
and parameterizable building blocks.

The central design principle is:

```text
High-Level Algorithm
        │
        ▼
Reusable Arithmetic Engine
        │
        ▼
Parameterized Hardware
        │
        ▼
Different Performance / Resource Points
```

Rather than building completely independent implementations, the same
arithmetic engine is configured differently to explore the impact of hardware
parallelism.

This makes the project useful for studying:

- FPGA-based signal processing.
- Hardware/software co-design.
- Fixed-point arithmetic.
- Multiply-accumulate architectures.
- FPGA resource utilization.
- Hardware parallelism.
- Latency and throughput.
- RTL design and control.
- FPGA implementation and debugging.

---

# 24. Expected Outcome

The completed project is intended to demonstrate a complete FPGA-based
signal-processing accelerator starting from software-prepared inertial sensor
data and ending with hardware-generated feature data.

The expected system will provide:

1. A Python-based fixed-point reference model.
2. An FPGA implementation of an 8-tap FIR filter for each accelerometer axis.
3. A reusable parameterizable MAC engine.
4. Sequential and parallel hardware configurations.
5. A vector feature extraction engine.
6. FPGA input and output memory.
7. A control FSM coordinating the complete processing pipeline.
8. Integration on the Nexys A7-100T FPGA platform.
9. A method for FPGA data readback and internal debugging.
10. A quantitative comparison of sequential and parallel architectures.

The final evaluation will focus on the fundamental hardware design trade-off:

```text
                    More Parallelism
                          │
                          ▼
                  More Hardware Resources
                          │
                          ▼
                    Lower Latency
                          │
                          ▼
                  Higher Throughput
```

versus:

```text
                   More Resource Sharing
                          │
                          ▼
                  Fewer Hardware Resources
                          │
                          ▼
                    Higher Latency
                          │
                          ▼
                  Lower Throughput
```

The project therefore demonstrates how the same signal-processing algorithm
can be mapped to different FPGA architectures depending on the desired
balance between **performance, resource utilization, latency, throughput,
and implementation complexity**.

---

# 25. Potential Future Extensions

The architecture can be extended beyond the initial representative
signal-processing pipeline.

Possible extensions include:

- Processing additional inertial-sensor channels such as gyroscope data.
- Supporting different FIR filter lengths.
- Supporting configurable filter coefficients.
- Increasing the number of samples processed per transaction.
- Increasing the level of MAC parallelism.
- Pipelining the FIR datapath.
- Developing a streaming sensor interface.
- Connecting an actual IMU sensor to the FPGA.
- Adding additional motion-related feature extraction.
- Developing a host interface for real-time data transfer.
- Exploring additional FPGA architectures and optimization techniques.

These extensions would allow the same accelerator architecture to evolve from
a controlled FPGA demonstration into a more complete wearable-sensor
processing platform.
