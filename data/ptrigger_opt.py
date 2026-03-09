import numpy as np
import array
import ROOT

def optimize_trigger_config(data_path, labels_path, output_root="trigger_optimization.root", output_pdf="trigger_optimization_report.pdf"):
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    X_int = (X_test * 64).astype(np.int32)
    # Duplicate channels 0-3 to 4-7
    X_8ch = np.concatenate((X_int, X_int), axis=1)
    
    signal_mask = (y_test == 1)
    noise_mask = (y_test == 0)
    total_signals = np.sum(signal_mask)
    total_noise = np.sum(noise_mask)
    total_events = total_signals + total_noise

    MAX_TRIGGER_RATE = 1.0 / 80.0
    
    max_amps_per_event = np.max(X_8ch, axis=(1, 2))
    sig_max_amps = max_amps_per_event[signal_mask]
    noise_max_amps = max_amps_per_event[noise_mask]
    max_amp_overall = int(np.max(max_amps_per_event))

    thresholds = np.arange(0, max_amp_overall + 1, 1) 
    bin_thresholds_to_test = [4, 6, 8] 

    graphs_eff, graphs_fpr, graphs_roc, graphs_rate, graphs_pur = {}, {}, {}, {}, {}
    colors = {4: ROOT.kBlue, 6: ROOT.kOrange+1, 8: ROOT.kGreen+2}

    print(f"Sweeping {len(thresholds)} individual thresholds for maximum smoothness")
    
    safe_thresholds = {}
    safe_efficiencies = {}

    for bin_thr in bin_thresholds_to_test:
        eff_vals, fpr_vals, rate_vals, pur_vals, thr_vals = [array.array('d') for _ in range(5)]
        
        found_safe = False
        safe_thr = None
        safe_eff = None
        
        for thresh in thresholds:
            crossed_thresh = (X_8ch > thresh)
            
            gates_open = np.zeros_like(crossed_thresh)
            
            WINDOW_SIZE = 32
            for shift in range(WINDOW_SIZE):
                if shift == 0:
                    gates_open |= crossed_thresh
                else:
                    gates_open[:, :, shift:] |= crossed_thresh[:, :, :-shift]
                    
            multiplicity = np.sum(gates_open, axis=1)
            event_triggered = np.any(multiplicity >= bin_thr, axis=1)
            
            tp = np.sum(event_triggered & signal_mask)
            fp = np.sum(event_triggered & noise_mask)
            tot_trig = tp + fp
            
            tpr = tp / total_signals if total_signals > 0 else 0.0
            fpr = fp / total_noise if total_noise > 0 else 0.0
            trig_rate = tot_trig / total_events if total_events > 0 else 0.0
            purity = tp / tot_trig if tot_trig > 0 else 1.0 
            
            # Check 1/80 intersection
            if not found_safe and trig_rate <= MAX_TRIGGER_RATE:
                safe_thr = thresh
                safe_eff = tpr
                found_safe = True
                
            eff_vals.append(tpr)
            fpr_vals.append(fpr)
            rate_vals.append(trig_rate)
            pur_vals.append(purity)
            thr_vals.append(thresh)
            
        safe_thresholds[bin_thr] = safe_thr
        safe_efficiencies[bin_thr] = safe_eff
            
        n_points = len(thresholds)
        
        graphs_eff[bin_thr] = ROOT.TGraph(n_points, thr_vals, eff_vals)
        graphs_eff[bin_thr].SetLineColor(colors[bin_thr])
        graphs_eff[bin_thr].SetLineWidth(2)
        graphs_eff[bin_thr].SetName(f"eff_bin_{bin_thr}")
        
        graphs_fpr[bin_thr] = ROOT.TGraph(n_points, thr_vals, fpr_vals)
        graphs_fpr[bin_thr].SetLineColor(colors[bin_thr])
        graphs_fpr[bin_thr].SetLineStyle(2)
        graphs_fpr[bin_thr].SetLineWidth(2)
        graphs_fpr[bin_thr].SetName(f"fpr_bin_{bin_thr}")
        
        graphs_roc[bin_thr] = ROOT.TGraph(n_points, fpr_vals, eff_vals)
        graphs_roc[bin_thr].SetLineColor(colors[bin_thr])
        graphs_roc[bin_thr].SetLineWidth(2)
        graphs_roc[bin_thr].SetName(f"roc_bin_{bin_thr}")

        graphs_rate[bin_thr] = ROOT.TGraph(n_points, thr_vals, rate_vals)
        graphs_rate[bin_thr].SetLineColor(colors[bin_thr])
        graphs_rate[bin_thr].SetLineWidth(2)
        graphs_rate[bin_thr].SetName(f"rate_bin_{bin_thr}")

        graphs_pur[bin_thr] = ROOT.TGraph(n_points, thr_vals, pur_vals)
        graphs_pur[bin_thr].SetLineColor(colors[bin_thr])
        graphs_pur[bin_thr].SetLineWidth(2)
        graphs_pur[bin_thr].SetName(f"pur_bin_{bin_thr}")

    print("Opening ROOT file and saving...")
    ROOT.gROOT.SetBatch(True) 
    
    root_file = ROOT.TFile(output_root, "RECREATE")
    
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
    
    h_noise.SetMinimum(0.5) 
    h_sig.SetMinimum(0.5)

    h_noise.Draw("HIST")
    h_sig.Draw("HIST SAME")
    ROOT.gPad.SetLogy()
    
    leg_hist = ROOT.TLegend(0.65, 0.75, 0.88, 0.88)
    leg_hist.SetBorderSize(1)
    leg_hist.AddEntry(h_sig, "Neutrino Signals", "f")
    leg_hist.AddEntry(h_noise, "Background Noise", "f")
    leg_hist.Draw()
    
    c_hist.Write()
    c_hist.Print(output_pdf + "(") 

# --- Canvas 2: Total Trigger Rate ---
    c_rate = ROOT.TCanvas("c_rate", "Total Trigger Rate", 800, 600)
    mg_rate = ROOT.TMultiGraph()
    mg_rate.SetTitle("Total Trigger Rate vs Threshold")
    for b in bin_thresholds_to_test: mg_rate.Add(graphs_rate[b])
    mg_rate.SetMinimum(1e-5) # Prevent log(0) error
    mg_rate.Draw("AL")
    
    # FORCE AXES DRAWING
    mg_rate.GetXaxis().SetTitle("Hardware ADC Threshold (Physical Amplitude * 64)")
    mg_rate.GetYaxis().SetTitle("Total Trigger Rate (Triggers / Total Events)")
    
    limit_line = ROOT.TLine(0, MAX_TRIGGER_RATE, max_amp_overall, MAX_TRIGGER_RATE)
    limit_line.SetLineColor(ROOT.kRed)
    limit_line.SetLineStyle(9)
    limit_line.SetLineWidth(2)
    limit_line.Draw("same")
    
    leg_rate = ROOT.TLegend(0.55, 0.65, 0.88, 0.88)
    leg_rate.SetHeader("Multiplicity (BIN_THR)", "C")
    leg_rate.SetBorderSize(1)
    
    for b in bin_thresholds_to_test:
        leg_rate.AddEntry(graphs_rate[b], f"BIN_THR = {b}", "l")
        if safe_thresholds[b] is not None:
            st = safe_thresholds[b]
            vl = ROOT.TLine(st, 1e-5, st, MAX_TRIGGER_RATE)
            vl.SetLineColor(colors[b])
            vl.SetLineStyle(3)
            vl.Draw("same")
            txt = ROOT.TLatex()
            txt.SetTextSize(0.03)
            txt.SetTextColor(colors[b])
            # Show both HW threshold and Physical threshold
            txt.DrawLatex(st + 5, MAX_TRIGGER_RATE * 1.5, f"HW:{st} (Phys:{st/64:.2f})")

    leg_rate.AddEntry(limit_line, "CNN Limit (1/80)", "l")
    leg_rate.Draw()
    ROOT.gPad.SetLogy()
    ROOT.gPad.Modified() # Force update
    ROOT.gPad.Update()   # Force update
    
    c_rate.Write()
    c_rate.Print(output_pdf) 

    # --- Canvas 3: Efficiency & FPR ---
    c_rates = ROOT.TCanvas("c_rates", "Efficiency and FPR", 800, 600)
    mg_rates = ROOT.TMultiGraph()
    mg_rates.SetTitle("Efficiency (Solid) & FPR (Dashed) vs Threshold")
    for b in bin_thresholds_to_test:
        mg_rates.Add(graphs_eff[b])
        mg_rates.Add(graphs_fpr[b])
    mg_rates.Draw("AL")
    
    # FORCE AXES DRAWING
    mg_rates.GetXaxis().SetTitle("Hardware ADC Threshold (Physical Amplitude * 64)")
    mg_rates.GetYaxis().SetTitle("Rate (0.0 to 1.0)")
    
    leg_rates = ROOT.TLegend(0.50, 0.50, 0.88, 0.88)
    leg_rates.SetBorderSize(1)
    for b in bin_thresholds_to_test:
        eff_str = f"Eff: {safe_efficiencies[b]*100:.1f}%" if safe_efficiencies[b] else "N/A"
        leg_rates.AddEntry(graphs_eff[b], f"BIN_THR={b} Eff ({eff_str})", "l")
        leg_rates.AddEntry(graphs_fpr[b], f"BIN_THR={b} FPR", "l")
    leg_rates.Draw()
    ROOT.gPad.Modified()
    ROOT.gPad.Update()
    
    c_rates.Write()
    c_rates.Print(output_pdf)

    # --- Canvas 4: ROC Curve ---
    c_roc = ROOT.TCanvas("c_roc", "ROC Curve", 800, 600)
    mg_roc = ROOT.TMultiGraph()
    mg_roc.SetTitle("ROC Curve")
    for b in bin_thresholds_to_test: mg_roc.Add(graphs_roc[b])
    mg_roc.Draw("AL")
    
    # FORCE AXES DRAWING
    mg_roc.GetXaxis().SetTitle("False Alarm Rate (FPR)")
    mg_roc.GetYaxis().SetTitle("Trigger Efficiency (TPR)")
    
    ROOT.gPad.SetLogx()
    
    leg_roc = ROOT.TLegend(0.65, 0.15, 0.88, 0.35)
    leg_roc.SetBorderSize(1)
    for b in bin_thresholds_to_test:
        leg_roc.AddEntry(graphs_roc[b], f"BIN_THR = {b}", "l")
    leg_roc.Draw()
    ROOT.gPad.Modified()
    ROOT.gPad.Update()
    
    c_roc.Write()
    c_roc.Print(output_pdf) 
    
    # --- Canvas 5: Purity vs Threshold ---
    c_pur = ROOT.TCanvas("c_pur", "Signal Purity", 800, 600)
    mg_pur = ROOT.TMultiGraph()
    mg_pur.SetTitle("Signal Purity of Triggered Events")
    for b in bin_thresholds_to_test: mg_pur.Add(graphs_pur[b])
    mg_pur.Draw("AL")
    
    # FORCE AXES DRAWING
    mg_pur.GetXaxis().SetTitle("Hardware ADC Threshold (Physical Amplitude * 64)")
    mg_pur.GetYaxis().SetTitle("Purity (True Positives / Total Triggers)")
    
    leg_pur = ROOT.TLegend(0.65, 0.15, 0.88, 0.35)
    leg_pur.SetBorderSize(1)
    for b in bin_thresholds_to_test:
        leg_pur.AddEntry(graphs_pur[b], f"BIN_THR = {b}", "l")
    leg_pur.Draw()
    ROOT.gPad.Modified()
    ROOT.gPad.Update()
    
    c_pur.Write()
    c_pur.Print(output_pdf + ")")

    root_file.Close()
    print(f"Success! Data saved to {output_root}")
    print(f"And compiled into {output_pdf}")

if __name__ == "__main__":
    optimize_trigger_config("X_test_data.npy", "y_test_labels.npy")