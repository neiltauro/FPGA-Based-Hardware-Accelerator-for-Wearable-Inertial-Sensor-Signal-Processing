#!/usr/bin/env python3
"""
reference_model.py

Software reference model implementing the exact same fixed-point arithmetic
as the RTL (fir_filter.v + vector_engine.v), so its output can be compared
directly against RTL/hardware simulation results (Section 10 of the
project proposal: "Software Reference Model").

Pipeline, matching accelerator_top.v:
    for each sample n:
        for each axis in {Ax, Ay, Az}:
            y_axis[n] = FIR_8tap(axis, coeffs)      # Q1.15, saturated
        mag_sq[n] = y_ax[n]^2 + y_ay[n]^2 + y_az[n]^2   # unscaled Q2.30

All arithmetic below is done in Python integers (not floats) and mirrors
mac_engine.v / fir_filter.v / vector_engine.v exactly:
  - multiply:      standard integer multiply (no rounding)
  - accumulate:    integer sum
  - FIR rescale:   arithmetic right shift by FRAC_BITS (floor, matches >>>)
  - FIR saturate:  clip to signed 16-bit range
  - vector engine: no rescale, no saturation beyond clipping negatives to 0
                    (mag_sq is mathematically non-negative; this matches
                    vector_engine.v's defensive clamp)

Usage:
    python3 reference_model.py
Reads:
    ../data/dataset_raw.csv   (columns ax_q15, ay_q15, az_q15)
    ../data/coeffs_q15.txt    (tap, float, q15, hex)
Writes:
    ../data/expected_output.csv   (index, mag_sq, filtered_ax/ay/az)
    ../data/expected_output.hex   (one 8-hex-digit line per sample, for
                                    $readmemh-based RTL comparison)
"""

import csv

DATA_W    = 16
COEF_W    = 16
FRAC_BITS = 15
TAPS      = 8
OUT_W     = 32

DATA_DIR = "../data"


def load_coeffs(path):
    coeffs = [0] * TAPS
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.split()
            idx = int(parts[0])
            q15 = int(parts[2])
            coeffs[idx] = q15
    return coeffs


def load_dataset(path):
    ax, ay, az = [], [], []
    with open(path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            ax.append(int(row["ax_q15"]))
            ay.append(int(row["ay_q15"]))
            az.append(int(row["az_q15"]))
    return ax, ay, az


def sat16(value: int) -> int:
    qmax = (1 << (DATA_W - 1)) - 1
    qmin = -(1 << (DATA_W - 1))
    if value > qmax:
        return qmax
    if value < qmin:
        return qmin
    return value


def fir_stream(samples, coeffs):
    """Streaming 8-tap FIR, bit-exact with fir_filter.v: window[0] is the
    newest sample, window[TAPS-1] the oldest; y[n] = sum(h_i * window[i])
    rescaled by an arithmetic right shift of FRAC_BITS and saturated."""
    window = [0] * TAPS
    out = []
    for x in samples:
        window = [x] + window[:-1]   # shift in newest at index 0
        acc = sum(h * w for h, w in zip(coeffs, window))
        rescaled = acc >> FRAC_BITS  # Python's >> on ints matches arithmetic shift for our sign convention
        out.append(sat16(rescaled))
    return out


def mag_sq(fax, fay, faz):
    val = fax * fax + fay * fay + faz * faz
    if val < 0:          # defensive clamp mirroring vector_engine.v; should
        val = 0          # not occur since squares are always non-negative
    out_max = (1 << OUT_W) - 1
    if val > out_max:
        val = out_max
    return val


def main():
    coeffs = load_coeffs(f"{DATA_DIR}/coeffs_q15.txt")
    ax, ay, az = load_dataset(f"{DATA_DIR}/dataset_raw.csv")
    n = len(ax)

    fax = fir_stream(ax, coeffs)
    fay = fir_stream(ay, coeffs)
    faz = fir_stream(az, coeffs)

    mags = [mag_sq(fax[i], fay[i], faz[i]) for i in range(n)]

    with open(f"{DATA_DIR}/expected_output.csv", "w") as f:
        f.write("index,filtered_ax,filtered_ay,filtered_az,mag_sq\n")
        for i in range(n):
            f.write(f"{i},{fax[i]},{fay[i]},{faz[i]},{mags[i]}\n")

    with open(f"{DATA_DIR}/expected_output.hex", "w") as f:
        for m in mags:
            f.write(f"{m:08x}\n")

    print(f"Processed {n} samples through the reference model")
    print(f"Wrote {DATA_DIR}/expected_output.csv")
    print(f"Wrote {DATA_DIR}/expected_output.hex")
    print()
    print(f"{'idx':>4} {'f_ax':>7} {'f_ay':>7} {'f_az':>7} {'mag_sq':>12}")
    for i in range(min(n, 8)):
        print(f"{i:>4} {fax[i]:>7} {fay[i]:>7} {faz[i]:>7} {mags[i]:>12}")
    if n > 8:
        print(f"... ({n - 8} more samples)")


if __name__ == "__main__":
    main()
