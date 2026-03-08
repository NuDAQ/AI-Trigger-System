import numpy as np
import array
import ROOT

def optimize_trigger_config(data_path, labels_path, output_pdf="trigger_optimization_report.pdf"):
    print("Loading data...")
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    # Scale to match VHDL fixed-point math
    X_int = (X_test * 64).astype(np.int32)
    # Duplicate channels 0-3 to 4-7
    X_8ch = np.concatenate((X_int, X_int), axis=1)
    
    signal_mask = (y_test == 1)
    noise_mask = (y_test == 0)
    total_signals = np.sum(signal_mask)
    total_noise = np.sum(noise_mask)
    total_events = total_signals + total_noise

    MAX_TRIGGER_RATE = 1.0 / 80.0
    
    # ---------------------------------------------------------
    # NEW: Calculate max amplitude per event for the histogram
    # ---------------------------------------------------------
    max_amps_per_event = np.max(X_8ch, axis=(1, 2))
    sig_max_amps = max_amps_per_event[signal_mask]
    noise_max_amps = max_amps_per_event[noise_mask]
    max_amp_overall = int(np.max(max_amps_per_event))

    # SMOOTHING FIX: Step size of 1 tests every exact integer threshold
    thresholds = np.arange(0, max_amp_overall + 1, 1) 
    bin_thresholds_to_test = [4, 6, 8] 

    graphs_eff, graphs_fpr, graphs_roc, graphs_rate, graphs_pur = {}, {}, {}, {}, {}
    colors = {4: ROOT.kBlue, 6: ROOT.kOrange+1, 8: ROOT.kGreen+2}

    print(f"Sweeping {len(thresholds)} individual thresholds for maximum smoothness...")
    
    for bin_thr in bin_thresholds_to_test:
        eff_vals, fpr_vals, rate_vals, pur_vals, thr_vals = [array.array('d') for _ in range(5)]
        
        for thresh in thresholds:
            # Vectorized VHDL emulation
            crossed_thresh = (X_8ch > thresh)
            gates_open = np.maximum.accumulate(crossed_thresh, axis=2)
            multiplicity = np.sum(gates_open, axis=1)
            event_triggered = np.any(multiplicity >= bin_thr, axis=1)
            
            # Metrics
            tp = np.sum(event_triggered & signal_mask)
            fp = np.sum(event_triggered & noise_mask)
            tot_trig = tp + fp
            
            tpr = tp / total_signals if total_signals > 0 else 0.0
            fpr = fp / total_noise if total_noise > 0 else 0.0
            trig_rate = tot_trig / total_events if total_events > 0 else 0.0
            purity = tp / tot_trig if tot_trig > 0 else 1.0 # 1.0 if no triggers
            
            eff_vals.append(tpr)
            fpr_vals.append(fpr)
            rate_vals.append(trig_rate)
            pur_vals.append(purity)
            thr_vals.append(thresh)
            
        n_points = len(thresholds)
        
        graphs_eff[bin_thr] = ROOT.TGraph(n_points, thr_vals, eff_vals)
        graphs_eff[bin_thr].SetLineColor(colors[bin_thr])
        graphs_eff[bin_thr].SetLineWidth(2)
        
        graphs_fpr[bin_thr] = ROOT.TGraph(n_points, thr_vals, fpr_vals)
        graphs_fpr[bin_thr].SetLineColor(colors[bin_thr])
        graphs_fpr[bin_thr].SetLineStyle(2)
        graphs_fpr[bin_thr].SetLineWidth(2)
        
        graphs_roc[bin_thr] = ROOT.TGraph(n_points, fpr_vals, eff_vals)
        graphs_roc[bin_thr].SetLineColor(colors[bin_thr])
        graphs_roc[bin_thr].SetLineWidth(2)

        graphs_rate[bin_thr] = ROOT.TGraph(n_points, thr_vals, rate_vals)
        graphs_rate[bin_thr].SetLineColor(colors[bin_thr])
        graphs_rate[bin_thr].SetLineWidth(2)

        graphs_pur[bin_thr] = ROOT.TGraph(n_points, thr_vals, pur_vals)
        graphs_pur[bin_thr].SetLineColor(colors[bin_thr])
        graphs_pur[bin_thr].SetLineWidth(2)

    print("Compiling canvases into PDF...")
    # Prevent ROOT from trying to pop up X11 windows while generating
    ROOT.gROOT.SetBatch(True) 
    
    # --- Canvas 1: Max Amplitude Distribution ---
    c_hist = ROOT.TCanvas("c_hist", "Amplitude Distributions", 800, 600)
    h_sig = ROOT.TH1F("h_sig", "Max Amplitude per Event;Hardware ADC Peak Value;Events", 100, 0, max_amp_overall)
    h_noise = ROOT.TH1F("h_noise", "Max Amplitude per Event", 100, 0, max_amp_overall)
    
    for val in sig_max_amps: h_sig.Fill(val)
    for val in noise_max_amps: h_noise.Fill(val)
        
    h_noise.SetFillColorAlpha(ROOT.kRed, 0.3)
    h_noise.SetLineColor(ROOT.kRed)
    h_sig.SetFillColorAlpha(ROOT.kBlue, 0.5)
    h_sig.SetLineColor(ROOT.kBlue)
    
    h_noise.Draw("HIST")
    h_sig.Draw("HIST SAME")
    ROOT.gPad.SetLogy()
    
    leg_hist = ROOT.TLegend(0.7, 0.7, 0.9, 0.9)
    leg_hist.AddEntry(h_sig, "Neutrino Signals", "f")
    leg_hist.AddEntry(h_noise, "Background Noise", "f")
    leg_hist.Draw()
    
    c_hist.Print(output_pdf + "(") # OPEN PDF

    # --- Canvas 2: Total Trigger Rate ---
    c_rate = ROOT.TCanvas("c_rate", "Total Trigger Rate", 800, 600)
    mg_rate = ROOT.TMultiGraph()
    mg_rate.SetTitle("Total Trigger Rate vs Threshold;Hardware ADC Threshold;Trigger Rate")
    for b in bin_thresholds_to_test: mg_rate.Add(graphs_rate[b])
    mg_rate.Draw("AL")
    
    limit_line = ROOT.TLine(0, MAX_TRIGGER_RATE, max_amp_overall, MAX_TRIGGER_RATE)
    limit_line.SetLineColor(ROOT.kRed)
    limit_line.SetLineStyle(9)
    limit_line.SetLineWidth(2)
    limit_line.Draw("same")
    
    ROOT.gPad.SetLogy()
    c_rate.BuildLegend(0.7, 0.7, 0.9, 0.9, "Multiplicity (BIN_THR)")
    c_rate.Print(output_pdf) # ADD TO PDF

    # --- Canvas 3: Efficiency & FPR ---
    c_rates = ROOT.TCanvas("c_rates", "Efficiency and FPR", 800, 600)
    mg_rates = ROOT.TMultiGraph()
    mg_rates.SetTitle("Efficiency (Solid) & FPR (Dashed) vs Threshold;Hardware ADC Threshold;Rate")
    for b in bin_thresholds_to_test:
        mg_rates.Add(graphs_eff[b])
        mg_rates.Add(graphs_fpr[b])
    mg_rates.Draw("AL")
    c_rates.BuildLegend(0.7, 0.5, 0.9, 0.9)
    c_rates.Print(output_pdf) # ADD TO PDF

    # --- Canvas 4: ROC Curve ---
    c_roc = ROOT.TCanvas("c_roc", "ROC Curve", 800, 600)
    mg_roc = ROOT.TMultiGraph()
    mg_roc.SetTitle("ROC Curve;False Alarm Rate (FPR);Trigger Efficiency (TPR)")
    for b in bin_thresholds_to_test: mg_roc.Add(graphs_roc[b])
    mg_roc.Draw("AL")
    ROOT.gPad.SetLogx()
    c_roc.BuildLegend(0.7, 0.1, 0.9, 0.3)
    c_roc.Print(output_pdf) # ADD TO PDF
    
    # --- Canvas 5: Purity vs Threshold ---
    c_pur = ROOT.TCanvas("c_pur", "Signal Purity", 800, 600)
    mg_pur = ROOT.TMultiGraph()
    mg_pur.SetTitle("Signal Purity of Triggered Events;Hardware ADC Threshold;Purity (TP / Total Triggers)")
    for b in bin_thresholds_to_test: mg_pur.Add(graphs_pur[b])
    mg_pur.Draw("AL")
    c_pur.BuildLegend(0.7, 0.1, 0.9, 0.3)
    c_pur.Print(output_pdf + ")") # CLOSE PDF

    print(f"Success! All 5 highly-smoothed plots compiled into {output_pdf}")

if __name__ == "__main__":
    optimize_trigger_config("X_test_data.npy", "y_test_labels.npy")
    