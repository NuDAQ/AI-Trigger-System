#!/usr/bin/env python3
"""Plot DAQ bring-up score CSVs produced by scripts/run_bringup_sim.py."""

from __future__ import annotations

import argparse
import csv
import os
from pathlib import Path
from statistics import mean


def read_rows(path: Path) -> list[dict[str, str]]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as csv_file:
        return list(csv.DictReader(csv_file))


def score_values(rows: list[dict[str, str]]) -> list[float]:
    return [float(row["float_out"]) for row in rows]


def write_summary(
    out_dir: Path,
    zero_rows: list[dict[str, str]],
    bipolar_rows: list[dict[str, str]],
    polar_rows: list[dict[str, str]],
    long_monopolar_rows: list[dict[str, str]],
    erf_monopolar_rows: list[dict[str, str]],
) -> Path:
    out_path = out_dir / "bringup_score_summary.csv"
    summaries = []
    for name, rows in (
        ("zero", zero_rows),
        ("bipolar_sweep", bipolar_rows),
        ("polar_sweep", polar_rows),
        ("monopolar_100mv_100ns_sweep", long_monopolar_rows),
        ("monopolar_100mv_100ns_erf_tr100ns_sweep", erf_monopolar_rows),
    ):
        values = score_values(rows)
        if values:
            summaries.append({
                "stim_kind": name,
                "count": str(len(values)),
                "score_min": f"{min(values):.6f}",
                "score_max": f"{max(values):.6f}",
                "score_mean": f"{mean(values):.6f}",
            })

    if not summaries:
        raise SystemExit(f"no annotated score rows found under {out_dir}")

    with out_path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=list(summaries[0]))
        writer.writeheader()
        writer.writerows(summaries)
    return out_path


def build_plots(
    out_dir: Path,
    zero_rows: list[dict[str, str]],
    bipolar_rows: list[dict[str, str]],
    polar_rows: list[dict[str, str]],
    long_monopolar_rows: list[dict[str, str]],
    erf_monopolar_rows: list[dict[str, str]],
) -> None:
    mpl_config = out_dir / ".mplconfig"
    mpl_config.mkdir(parents=True, exist_ok=True)
    xdg_cache = out_dir / ".cache"
    xdg_cache.mkdir(parents=True, exist_ok=True)
    os.environ.setdefault("MPLCONFIGDIR", str(mpl_config))
    os.environ.setdefault("XDG_CACHE_HOME", str(xdg_cache))

    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    zero_scores = score_values(zero_rows)
    bipolar_scores = score_values(bipolar_rows)
    polar_scores = score_values(polar_rows)
    long_monopolar_scores = score_values(long_monopolar_rows)
    erf_monopolar_scores = score_values(erf_monopolar_rows)

    if bipolar_rows:
        offsets = [int(row["pulse_offset_sample"]) for row in bipolar_rows]
        plt.figure(figsize=(10, 4.8))
        plt.plot(offsets, bipolar_scores, marker=".", linewidth=1.0, label="ch0 bipolar pulse")
        if zero_scores:
            zero_mean = mean(zero_scores)
            plt.axhline(zero_mean, color="tab:orange", linestyle="--", label="zero mean")
            plt.fill_between(
                [min(offsets), max(offsets)],
                [min(zero_scores), min(zero_scores)],
                [max(zero_scores), max(zero_scores)],
                color="tab:orange",
                alpha=0.15,
                label="zero min/max",
            )
        plt.xlabel("Pulse start offset in 256-sample chunk")
        plt.ylabel("CNN score")
        plt.title("DAQ bring-up bipolar pulse score vs offset")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(out_dir / "score_vs_offset.png", dpi=160)
        plt.close()

    if polar_rows:
        offsets = [int(row["pulse_offset_sample"]) for row in polar_rows]
        plt.figure(figsize=(10, 4.8))
        plt.plot(offsets, polar_scores, marker=".", linewidth=1.0, label="ch0 polar pulse")
        if zero_scores:
            zero_mean = mean(zero_scores)
            plt.axhline(zero_mean, color="tab:orange", linestyle="--", label="zero mean")
            plt.fill_between(
                [min(offsets), max(offsets)],
                [min(zero_scores), min(zero_scores)],
                [max(zero_scores), max(zero_scores)],
                color="tab:orange",
                alpha=0.15,
                label="zero min/max",
            )
        plt.xlabel("Pulse start offset in 256-sample chunk")
        plt.ylabel("CNN score")
        plt.title("DAQ bring-up polar pulse score vs offset")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(out_dir / "polar_score_vs_offset.png", dpi=160)
        plt.close()

    if long_monopolar_rows:
        offsets = [int(row["pulse_offset_sample"]) for row in long_monopolar_rows]
        plt.figure(figsize=(10, 4.8))
        plt.plot(
            offsets,
            long_monopolar_scores,
            marker=".",
            linewidth=1.0,
            label="ch0 +100 mV x 100 ns monopolar pulse",
        )
        if zero_scores:
            zero_mean = mean(zero_scores)
            plt.axhline(zero_mean, color="tab:orange", linestyle="--", label="zero mean")
            plt.fill_between(
                [min(offsets), max(offsets)],
                [min(zero_scores), min(zero_scores)],
                [max(zero_scores), max(zero_scores)],
                color="tab:orange",
                alpha=0.15,
                label="zero min/max",
            )
        plt.axvline(0, color="tab:green", linestyle=":", label="front clipping ends")
        plt.axvline(156, color="tab:red", linestyle=":", label="back clipping starts")
        plt.xlabel("Nominal pulse start offset in 256-sample chunk")
        plt.ylabel("CNN score")
        plt.title("DAQ bring-up +100 mV x 100 ns monopolar pulse score vs offset")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(out_dir / "monopolar_100mv_100ns_score_vs_offset.png", dpi=160)
        plt.close()

    if erf_monopolar_rows:
        offsets = [int(row["pulse_offset_sample"]) for row in erf_monopolar_rows]
        plt.figure(figsize=(10, 4.8))
        plt.plot(
            offsets,
            erf_monopolar_scores,
            marker=".",
            linewidth=1.0,
            label="ch0 A=100 mV, width=100 ns, erf edges tr=tf=100 ns (peak about 80 mV)",
        )
        if zero_scores:
            zero_mean = mean(zero_scores)
            plt.axhline(zero_mean, color="tab:orange", linestyle="--", label="zero mean")
            plt.fill_between(
                [min(offsets), max(offsets)],
                [min(zero_scores), min(zero_scores)],
                [max(zero_scores), max(zero_scores)],
                color="tab:orange",
                alpha=0.15,
                label="zero min/max",
            )
        plt.axvline(0, color="tab:green", linestyle=":", label="rise 50% enters chunk")
        plt.axvline(156, color="tab:red", linestyle=":", label="fall 50% reaches boundary")
        plt.xlabel("Rising-edge 50% crossing offset in 256-sample chunk")
        plt.ylabel("CNN score")
        plt.title("DAQ bring-up band-limited monopolar pulse score vs offset")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(
            out_dir / "monopolar_100mv_100ns_erf_tr100ns_score_vs_offset.png",
            dpi=160,
        )
        plt.close()

    if (
        zero_scores
        or bipolar_scores
        or polar_scores
        or long_monopolar_scores
        or erf_monopolar_scores
    ):
        plt.figure(figsize=(8, 4.8))
        if zero_scores:
            plt.hist(zero_scores, bins=min(30, max(1, len(zero_scores))), alpha=0.65, label="zero")
        if bipolar_scores:
            plt.hist(bipolar_scores, bins=min(40, max(1, len(bipolar_scores))), alpha=0.65, label="bipolar sweep")
        if polar_scores:
            plt.hist(polar_scores, bins=min(40, max(1, len(polar_scores))), alpha=0.65, label="polar sweep")
        if long_monopolar_scores:
            plt.hist(
                long_monopolar_scores,
                bins=min(40, max(1, len(long_monopolar_scores))),
                alpha=0.65,
                label="100 mV x 100 ns monopolar sweep",
            )
        if erf_monopolar_scores:
            plt.hist(
                erf_monopolar_scores,
                bins=min(40, max(1, len(erf_monopolar_scores))),
                alpha=0.65,
                label="A=100 mV, width=100 ns, erf-edge tr=tf=100 ns sweep",
            )
        plt.xlabel("CNN score")
        plt.ylabel("Count")
        plt.title("DAQ bring-up score distribution")
        plt.grid(True, alpha=0.25)
        plt.legend()
        plt.tight_layout()
        plt.savefig(out_dir / "score_histogram.png", dpi=160)
        plt.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Plot zero and pulse-sweep bring-up score distributions.")
    parser.add_argument(
        "--out-dir",
        type=Path,
        default=Path("build/bringup_sim"),
        help="Directory containing generated bring-up case directories and annotated score CSVs.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    out_dir = args.out_dir.expanduser()
    zero_rows = read_rows(out_dir / "zero" / "scores_annotated.csv")
    bipolar_rows = read_rows(out_dir / "bipolar_sweep" / "scores_annotated.csv")
    polar_rows = read_rows(out_dir / "polar_sweep" / "scores_annotated.csv")
    long_monopolar_rows = read_rows(
        out_dir / "monopolar_100mv_100ns_sweep" / "scores_annotated.csv"
    )
    erf_monopolar_rows = read_rows(
        out_dir / "monopolar_100mv_100ns_erf_tr100ns_sweep" / "scores_annotated.csv"
    )

    summary = write_summary(
        out_dir,
        zero_rows,
        bipolar_rows,
        polar_rows,
        long_monopolar_rows,
        erf_monopolar_rows,
    )
    build_plots(
        out_dir,
        zero_rows,
        bipolar_rows,
        polar_rows,
        long_monopolar_rows,
        erf_monopolar_rows,
    )
    print(f"INFO: wrote {summary}")
    print(f"INFO: wrote {out_dir / 'score_vs_offset.png'}")
    print(f"INFO: wrote {out_dir / 'polar_score_vs_offset.png'}")
    print(f"INFO: wrote {out_dir / 'monopolar_100mv_100ns_score_vs_offset.png'}")
    print(f"INFO: wrote {out_dir / 'monopolar_100mv_100ns_erf_tr100ns_score_vs_offset.png'}")
    print(f"INFO: wrote {out_dir / 'score_histogram.png'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
