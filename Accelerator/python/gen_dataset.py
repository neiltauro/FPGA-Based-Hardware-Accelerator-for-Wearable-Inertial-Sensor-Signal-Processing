#!/usr/bin/env python3
"""
gen_dataset.py

Generates a representative tri-axial accelerometer dataset (or, if
DATASET_CSV points to a real recording, loads and converts that instead)
and converts it to Q1.15 fixed-point, matching the sample format expected
by accelerator_top's input BRAM.

This implements the "CSV -> Python preprocessing -> .mem file -> FPGA
BRAM" baseline data path from Section 9.1 of the project proposal.

Packing convention (must match accelerator_top.v's axis extraction):
    in_wr_data = {Az, Ay, Ax}   (Ax in the low 16 bits, Az in the high 16)

Outputs (written to ../data/):
  dataset_raw.csv   - the float dataset actually used (for the reference
                       model and for reproducibility)
  input.mem         - one line per sample, 12 hex digits (48 bits),
                       $readmemh-compatible, ready to preload the input
                       BRAM (bram_sync's INIT_FILE parameter) or to be
                       walked by a testbench driving the host write port.

Usage:
    python3 gen_dataset.py                  # synthetic dataset (default)
    python3 gen_dataset.py --csv path.csv   # convert a real recording
"""

import argparse
import numpy as np

DATA_W    = 16
NUM_SAMPLES = 64
FS_HZ     = 100.0

OUT_DIR = "../data"


def to_q15(x: np.ndarray) -> np.ndarray:
    """Convert float array (nominally in [-1, 1)) to signed 16-bit Q1.15
    integers with clipping saturation, matching the hardware convention."""
    scaled = np.round(x * (1 << (DATA_W - 1))).astype(np.int64)
    qmax = (1 << (DATA_W - 1)) - 1
    qmin = -(1 << (DATA_W - 1))
    return np.clip(scaled, qmin, qmax).astype(np.int32)


def synthetic_dataset(n: int, fs: float, seed: int = 0) -> np.ndarray:
    """Representative tri-axial accelerometer signal: a slow gravity-like
    component per axis plus a movement-band oscillation plus sensor noise,
    normalized to stay within the Q1.15 representable range."""
    rng = np.random.default_rng(seed)
    t = np.arange(n) / fs

    # Static orientation component (approximates gravity projection).
    gx, gy, gz = 0.05, 0.10, 0.60

    # Movement-band oscillation (a few Hz, typical of walking-type motion).
    move_x = 0.15 * np.sin(2 * np.pi * 1.8 * t)
    move_y = 0.10 * np.sin(2 * np.pi * 2.3 * t + 0.4)
    move_z = 0.08 * np.sin(2 * np.pi * 1.5 * t + 1.1)

    # Sensor noise (higher frequency content the FIR filter should attenuate).
    noise_x = rng.normal(0, 0.03, n) + 0.05 * np.sin(2 * np.pi * 25 * t)
    noise_y = rng.normal(0, 0.03, n) + 0.05 * np.sin(2 * np.pi * 30 * t)
    noise_z = rng.normal(0, 0.03, n) + 0.05 * np.sin(2 * np.pi * 28 * t)

    ax = gx + move_x + noise_x
    ay = gy + move_y + noise_y
    az = gz + move_z + noise_z

    data = np.stack([ax, ay, az], axis=1)
    # Keep comfortably inside [-1, 1) so quantization saturation is not
    # exercised by ordinary samples (a couple of the unit tests exercise
    # saturation deliberately; this dataset should not need to).
    peak = np.max(np.abs(data))
    if peak > 0.9:
        data = data * (0.9 / peak)
    return data


def load_csv_dataset(path: str) -> np.ndarray:
    """Load a real recording with columns Ax,Ay,Az (float, already scaled
    to units of g or normalized to [-1, 1))."""
    arr = np.loadtxt(path, delimiter=",", skiprows=1)
    return arr[:, :3]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", type=str, default=None,
                         help="path to a real Ax,Ay,Az CSV recording")
    parser.add_argument("-n", "--num-samples", type=int, default=NUM_SAMPLES)
    args = parser.parse_args()

    if args.csv:
        data = load_csv_dataset(args.csv)
    else:
        data = synthetic_dataset(args.num_samples, FS_HZ)

    n = data.shape[0]
    q = to_q15(data)  # (n, 3) int16-range values: columns = [Ax, Ay, Az]

    # ---------------- dataset_raw.csv ----------------
    with open(f"{OUT_DIR}/dataset_raw.csv", "w") as f:
        f.write("ax,ay,az,ax_q15,ay_q15,az_q15\n")
        for i in range(n):
            f.write(f"{data[i,0]:.6f},{data[i,1]:.6f},{data[i,2]:.6f},"
                     f"{q[i,0]},{q[i,1]},{q[i,2]}\n")

    # ---------------- input.mem ----------------
    with open(f"{OUT_DIR}/input.mem", "w") as f:
        for i in range(n):
            ax_u = int(q[i, 0]) & 0xFFFF
            ay_u = int(q[i, 1]) & 0xFFFF
            az_u = int(q[i, 2]) & 0xFFFF
            packed = (az_u << 32) | (ay_u << 16) | ax_u
            f.write(f"{packed:012x}\n")

    print(f"Generated {n} samples")
    print(f"Wrote {OUT_DIR}/dataset_raw.csv")
    print(f"Wrote {OUT_DIR}/input.mem  ({n} lines, 12 hex digits each)")


if __name__ == "__main__":
    main()
