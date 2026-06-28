#!/usr/bin/env python3
"""Generate ROOT/PDF validation plots for the continuous AI trigger path."""

from __future__ import annotations

import argparse
import csv
import math
from array import array
from pathlib import Path

import ROOT


def read_rows(comparison_csv: Path, latency_csv: Path) -> list[dict[str, float | int]]:
    latency_by_sample: dict[int, float] = {}
    with latency_csv.open() as f:
        for row in csv.DictReader(f):
            latency_by_sample[int(row["sample_id"])] = float(row["latency_cycles_cnn"])

    rows: list[dict[str, float | int]] = []
    with comparison_csv.open() as f:
        for row in csv.DictReader(f):
            sample_id = int(row["sample_id"])
            rtl_score = float(row["rtl_score"])
            keras_score = float(row["keras_score"])
            residual = rtl_score - keras_score
            rows.append(
                {
                    "sample_id": sample_id,
                    "label": int(row["label_csv"]),
                    "rtl_score": rtl_score,
                    "keras_score": keras_score,
                    "residual": residual,
                    "abs_diff": abs(residual),
                    "latency_cycles": latency_by_sample.get(sample_id, 0.0),
                }
            )
    rows.sort(key=lambda r: int(r["sample_id"]))
    return rows


def mean(values: list[float]) -> float:
    return sum(values) / len(values) if values else 0.0


def quantile(values: list[float], q: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    pos = q * (len(ordered) - 1)
    lo = int(math.floor(pos))
    hi = int(math.ceil(pos))
    if lo == hi:
        return ordered[lo]
    return ordered[lo] + (pos - lo) * (ordered[hi] - ordered[lo])


def pearson(x: list[float], y: list[float]) -> float:
    if len(x) < 2:
        return 0.0
    mx = mean(x)
    my = mean(y)
    num = sum((a - mx) * (b - my) for a, b in zip(x, y))
    den_x = math.sqrt(sum((a - mx) ** 2 for a in x))
    den_y = math.sqrt(sum((b - my) ** 2 for b in y))
    return num / (den_x * den_y) if den_x and den_y else 0.0


def arr(values: list[float]) -> array:
    return array("d", values)


def configure_style() -> None:
    ROOT.gROOT.SetBatch(True)
    ROOT.gStyle.SetOptStat(0)
    ROOT.gStyle.SetTitleFont(42, "XYZ")
    ROOT.gStyle.SetLabelFont(42, "XYZ")
    ROOT.gStyle.SetTextFont(42)
    ROOT.gStyle.SetLegendFont(42)
    ROOT.gStyle.SetTitleSize(0.045, "XYZ")
    ROOT.gStyle.SetLabelSize(0.040, "XYZ")
    ROOT.gStyle.SetPadLeftMargin(0.12)
    ROOT.gStyle.SetPadRightMargin(0.05)
    ROOT.gStyle.SetPadBottomMargin(0.12)
    ROOT.gStyle.SetPadTopMargin(0.08)
    ROOT.gStyle.SetPalette(ROOT.kViridis)


def legend(x1: float, y1: float, x2: float, y2: float) -> ROOT.TLegend:
    leg = ROOT.TLegend(x1, y1, x2, y2)
    leg.SetBorderSize(0)
    leg.SetFillStyle(0)
    leg.SetTextSize(0.034)
    return leg


def draw_text(x: float, y: float, text: str, size: float = 0.035) -> None:
    latex = ROOT.TLatex()
    latex.SetNDC(True)
    latex.SetTextFont(42)
    latex.SetTextSize(size)
    latex.DrawLatex(x, y, text)


def text_box(x1: float, y1: float, x2: float, y2: float, lines: list[str]) -> ROOT.TPaveText:
    box = ROOT.TPaveText(x1, y1, x2, y2, "NDC")
    box.SetFillColor(ROOT.kWhite)
    box.SetFillStyle(1001)
    box.SetBorderSize(0)
    box.SetTextFont(42)
    box.SetTextSize(0.030)
    box.SetTextAlign(12)
    for line in lines:
        box.AddText(line)
    box.Draw()
    return box


def write_summary(rows: list[dict[str, float | int]], threshold: float, out_path: Path) -> None:
    rtl = [float(r["rtl_score"]) for r in rows]
    keras = [float(r["keras_score"]) for r in rows]
    abs_diff = [float(r["abs_diff"]) for r in rows]
    rtl_conf = [[0, 0], [0, 0]]
    keras_conf = [[0, 0], [0, 0]]
    label_count = [0, 0]
    agree = 0

    for r in rows:
        label = int(r["label"])
        label_count[label] += 1
        rtl_pred = int(float(r["rtl_score"]) > threshold)
        keras_pred = int(float(r["keras_score"]) > threshold)
        rtl_conf[label][rtl_pred] += 1
        keras_conf[label][keras_pred] += 1
        agree += int(rtl_pred == keras_pred)

    n = len(rows)
    out_path.write_text(
        "\n".join(
            [
                "Continuous trigger full-dataset validation",
                f"Samples: {n}",
                f"Decision threshold: {threshold:.6f}",
                f"Labels: class 0 = {label_count[0]}, class 1 = {label_count[1]}",
                f"RTL accuracy at threshold: {(rtl_conf[0][0] + rtl_conf[1][1]) / n:.6f}",
                f"Keras accuracy at threshold: {(keras_conf[0][0] + keras_conf[1][1]) / n:.6f}",
                f"RTL/Keras prediction agreement at threshold: {agree / n:.6f}",
                f"RTL/Keras score correlation: {pearson(rtl, keras):.6f}",
                f"Mean absolute score difference: {mean(abs_diff):.6f}",
                f"Median absolute score difference: {quantile(abs_diff, 0.50):.6f}",
                f"95% absolute score difference: {quantile(abs_diff, 0.95):.6f}",
                f"Maximum absolute score difference: {max(abs_diff):.6f}",
                "",
            ]
        )
    )


def build_plots(rows: list[dict[str, float | int]], out_dir: Path, threshold: float) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    configure_style()

    sample_max = max(int(r["sample_id"]) for r in rows) + 1
    rtl = [float(r["rtl_score"]) for r in rows]
    keras = [float(r["keras_score"]) for r in rows]
    abs_diff = [float(r["abs_diff"]) for r in rows]
    latency = [float(r["latency_cycles"]) for r in rows]
    corr = pearson(rtl, keras)

    by_label = {0: [], 1: []}
    rtl_conf = [[0, 0], [0, 0]]
    keras_conf = [[0, 0], [0, 0]]
    agree = 0
    for r in rows:
        label = int(r["label"])
        by_label[label].append(r)
        rtl_pred = int(float(r["rtl_score"]) > threshold)
        keras_pred = int(float(r["keras_score"]) > threshold)
        rtl_conf[label][rtl_pred] += 1
        keras_conf[label][keras_pred] += 1
        agree += int(rtl_pred == keras_pred)

    root_file = ROOT.TFile(str(out_dir / "continuous_validation.root"), "RECREATE")
    report_pdf = out_dir / "continuous_validation_report.pdf"
    keepalive = []

    # 1. RTL score vs Keras score scatter.
    c_scatter = ROOT.TCanvas("c_score_scatter", "RTL score vs Keras score", 900, 760)
    frame = c_scatter.DrawFrame(-7.0, -7.0, 25.0, 25.0, "Full-Dataset Score Agreement;Keras score;RTL score")
    frame.GetXaxis().CenterTitle()
    frame.GetYaxis().CenterTitle()
    graphs = []
    for label, color, marker in [(0, ROOT.kAzure + 1, 20), (1, ROOT.kOrange + 7, 21)]:
        x = [float(r["keras_score"]) for r in by_label[label]]
        y = [float(r["rtl_score"]) for r in by_label[label]]
        g = ROOT.TGraph(len(x), arr(x), arr(y))
        g.SetName(f"g_score_scatter_class{label}")
        g.SetMarkerColor(color)
        g.SetMarkerStyle(marker)
        g.SetMarkerSize(0.65 if label == 0 else 0.75)
        g.Draw("P SAME")
        graphs.append(g)
    unity = ROOT.TLine(-7.0, -7.0, 25.0, 25.0)
    unity.SetLineColor(ROOT.kGray + 2)
    unity.SetLineStyle(2)
    unity.SetLineWidth(2)
    unity.Draw("SAME")
    xthr = ROOT.TLine(threshold, -7.0, threshold, 25.0)
    ythr = ROOT.TLine(-7.0, threshold, 25.0, threshold)
    for line in (xthr, ythr):
        line.SetLineColor(ROOT.kRed + 1)
        line.SetLineStyle(3)
        line.Draw("SAME")
    leg = legend(0.15, 0.72, 0.48, 0.88)
    leg.AddEntry(graphs[0], "Class 0", "p")
    leg.AddEntry(graphs[1], "Class 1", "p")
    leg.AddEntry(unity, "y = x", "l")
    leg.Draw()
    keepalive.extend(graphs + [unity, xthr, ythr, leg])
    draw_text(0.56, 0.20, f"Correlation = {corr:.4f}")
    draw_text(0.56, 0.15, f"Threshold = {threshold:.1f}")
    c_scatter.Write()
    c_scatter.Print(str(out_dir / "score_scatter_rtl_vs_keras.pdf"))
    c_scatter.Print(str(report_pdf) + "(")

    # 3. Residual vs sample index.
    c_res = ROOT.TCanvas("c_score_residual_by_sample", "Score residual by sample", 1000, 560)
    frame = c_res.DrawFrame(0.0, -5.0, float(sample_max), 5.0, "Score Residual by Sample;Sample ID;RTL score - Keras score")
    frame.GetXaxis().CenterTitle()
    frame.GetYaxis().CenterTitle()
    res_graphs = []
    for label, color, marker in [(0, ROOT.kAzure + 1, 20), (1, ROOT.kOrange + 7, 21)]:
        x = [float(r["sample_id"]) for r in by_label[label]]
        y = [float(r["residual"]) for r in by_label[label]]
        g = ROOT.TGraph(len(x), arr(x), arr(y))
        g.SetName(f"g_residual_class{label}")
        g.SetMarkerColor(color)
        g.SetMarkerStyle(marker)
        g.SetMarkerSize(0.55 if label == 0 else 0.65)
        g.Draw("P SAME")
        res_graphs.append(g)
    zero = ROOT.TLine(0.0, 0.0, float(sample_max), 0.0)
    zero.SetLineColor(ROOT.kGray + 2)
    zero.SetLineStyle(2)
    zero.SetLineWidth(2)
    zero.Draw("SAME")
    leg = legend(0.70, 0.76, 0.90, 0.88)
    leg.AddEntry(res_graphs[0], "Class 0", "p")
    leg.AddEntry(res_graphs[1], "Class 1", "p")
    leg.Draw()
    keepalive.extend(res_graphs + [zero, leg])
    c_res.Write()
    c_res.Print(str(out_dir / "score_residual_by_sample.pdf"))
    c_res.Print(str(report_pdf))

    # 4. Absolute score difference histogram.
    c_abs = ROOT.TCanvas("c_abs_score_diff_hist", "Absolute score difference", 850, 650)
    h_abs = ROOT.TH1D("h_abs_score_diff", "Absolute Score Difference;|RTL score - Keras score|;Events", 80, 0.0, 5.0)
    for value in abs_diff:
        h_abs.Fill(value)
    h_abs.SetLineColor(ROOT.kAzure + 2)
    h_abs.SetFillColorAlpha(ROOT.kAzure + 1, 0.35)
    h_abs.SetLineWidth(2)
    h_abs.Draw("HIST")
    draw_text(0.55, 0.82, f"Mean = {mean(abs_diff):.3f}")
    draw_text(0.55, 0.77, f"Median = {quantile(abs_diff, 0.50):.3f}")
    draw_text(0.55, 0.72, f"95% = {quantile(abs_diff, 0.95):.3f}")
    c_abs.Write()
    keepalive.append(h_abs)
    c_abs.Print(str(out_dir / "abs_score_diff_hist.pdf"))
    c_abs.Print(str(report_pdf))

    # 6. Confusion matrices.
    c_conf = ROOT.TCanvas("c_confusion_matrices", "Confusion matrices", 1100, 520)
    c_conf.Divide(2, 1)
    for pad, name, title, conf in [
        (1, "h_confusion_rtl_thr0", "RTL Trigger Decision", rtl_conf),
        (2, "h_confusion_keras_thr0", "Keras Trigger Decision", keras_conf),
    ]:
        c_conf.cd(pad)
        ROOT.gPad.SetRightMargin(0.14)
        ROOT.gPad.SetTopMargin(0.13)
        h = ROOT.TH2D(name, f"{title};Predicted class;True class", 2, -0.5, 1.5, 2, -0.5, 1.5)
        h.GetXaxis().SetBinLabel(1, "0")
        h.GetXaxis().SetBinLabel(2, "1")
        h.GetYaxis().SetBinLabel(1, "0")
        h.GetYaxis().SetBinLabel(2, "1")
        h.SetBinContent(1, 1, conf[0][0])
        h.SetBinContent(2, 1, conf[0][1])
        h.SetBinContent(1, 2, conf[1][0])
        h.SetBinContent(2, 2, conf[1][1])
        h.SetMarkerSize(1.8)
        h.Draw("COLZ TEXT")
        accuracy = (conf[0][0] + conf[1][1]) / len(rows)
        box_lines = [f"Accuracy = {100.0 * accuracy:.2f}%"]
        if pad == 2:
            box_lines.append(f"Common threshold = {threshold:.1f}")
        box = text_box(0.15, 0.73 if pad == 2 else 0.78, 0.48, 0.85, box_lines)
        keepalive.extend([h, box])
    c_conf.Write()
    c_conf.Print(str(out_dir / "confusion_matrices_threshold0.pdf"))
    c_conf.Print(str(report_pdf))

    # 9. Latency histogram.
    c_lat = ROOT.TCanvas("c_latency_hist", "Latency distribution", 850, 650)
    h_lat = ROOT.TH1D("h_latency_cycles", "End-to-End Latency;Latency (CLK_{CNN} cycles);Events", 20, 198.5, 206.5)
    for value in latency:
        h_lat.Fill(value)
    h_lat.SetLineColor(ROOT.kTeal + 3)
    h_lat.SetFillColorAlpha(ROOT.kTeal + 2, 0.35)
    h_lat.SetLineWidth(2)
    h_lat.Draw("HIST")
    draw_text(0.55, 0.82, f"Mean = {mean(latency):.3f} cycles")
    draw_text(0.55, 0.77, f"Samples = {len(rows)}")
    c_lat.Write()
    keepalive.append(h_lat)
    c_lat.Print(str(out_dir / "latency_hist.pdf"))
    c_lat.Print(str(report_pdf))

    # 10. Score distributions by label.
    c_dist = ROOT.TCanvas("c_score_distribution_by_label", "Score distributions by label", 1100, 520)
    c_dist.Divide(2, 1)
    for pad, prefix, title, score_key in [
        (1, "rtl", "RTL Score Distribution", "rtl_score"),
        (2, "keras", "Keras Score Distribution", "keras_score"),
    ]:
        c_dist.cd(pad)
        ROOT.gPad.SetLogy()
        h0 = ROOT.TH1D(f"h_{prefix}_score_class0", f"{title};Score;Events", 90, -7.0, 25.0)
        h1 = ROOT.TH1D(f"h_{prefix}_score_class1", f"{title};Score;Events", 90, -7.0, 25.0)
        for r in rows:
            (h0 if int(r["label"]) == 0 else h1).Fill(float(r[score_key]))
        h0.SetLineColor(ROOT.kAzure + 1)
        h0.SetFillColorAlpha(ROOT.kAzure + 1, 0.25)
        h1.SetLineColor(ROOT.kOrange + 7)
        h1.SetFillColorAlpha(ROOT.kOrange + 7, 0.30)
        for h in (h0, h1):
            h.SetLineWidth(2)
        h0.SetMinimum(0.5)
        h0.Draw("HIST")
        h1.Draw("HIST SAME")
        ymax = max(h0.GetMaximum(), h1.GetMaximum()) * 1.25
        thr = ROOT.TLine(threshold, 0.5, threshold, ymax)
        thr.SetLineColor(ROOT.kRed + 1)
        thr.SetLineStyle(3)
        thr.SetLineWidth(2)
        thr.Draw("SAME")
        leg = legend(0.62, 0.70, 0.88, 0.87)
        leg.AddEntry(h0, "Class 0", "f")
        leg.AddEntry(h1, "Class 1", "f")
        leg.AddEntry(thr, "Threshold", "l")
        leg.Draw()
        keepalive.extend([h0, h1, thr, leg])
    c_dist.Write()
    c_dist.Print(str(out_dir / "score_distribution_by_label.pdf"))
    c_dist.Print(str(report_pdf) + ")")

    write_summary(rows, threshold, out_dir / "continuous_validation_summary.txt")
    root_file.Write()
    root_file.Close()

    print(f"Wrote {out_dir / 'continuous_validation.root'}")
    print(f"Wrote {report_pdf}")
    print(f"RTL/Keras score correlation: {corr:.6f}")
    print(f"RTL/Keras prediction agreement at threshold {threshold:.1f}: {agree / len(rows):.6f}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--comparison-csv", type=Path, default=Path("build/vivado_sim_analysis_full/keras_comparison.csv"))
    parser.add_argument(
        "--latency-csv",
        type=Path,
        default=Path("AI_Trigger_System/AI_Trigger_System.sim/sim_1/behav/xsim/ai_trigger_results.csv"),
    )
    parser.add_argument("--out-dir", type=Path, default=Path("analysis/Continuous"))
    parser.add_argument("--threshold", type=float, default=0.0)
    args = parser.parse_args()
    rows = read_rows(args.comparison_csv, args.latency_csv)
    build_plots(rows, args.out_dir, args.threshold)


if __name__ == "__main__":
    main()
