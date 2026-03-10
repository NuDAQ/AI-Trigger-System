import numpy as np
import array
import ROOT
import subprocess

def optimize_trigger_config(data_path, labels_path, output_root="trigger_optimization.root", output_pdf="trigger_optimization_report.pdf"):
    print("Loading data")
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    signal_mask = (y_test == 1)
    noise_mask = (y_test == 0)
    
    pure_noise_waveforms = X_test[noise_mask]
    noise_rms = np.std(pure_noise_waveforms)
    print(f"Calculated Background Noise RMS: {noise_rms:.6f}")

    X_int = (X_test * 64).astype(np.int32)
    X_8ch = np.concatenate((X_int, X_int), axis=1)
    
    total_signals = np.sum(signal_mask)
    total_noise = np.sum(noise_mask)
    total_events = total_signals + total_noise

    # --- CNN Rate Limits ---
    RATE_1CNN = 1.0 / 80.0
    RATE_3CNN = 1.0 / 26.0
    RATE_4CNN = 1.0 / 19.5
    
    max_amps_per_event_hw = np.max(np.abs(X_8ch), axis=(1, 2))
    max_amps_per_event_rms = (max_amps_per_event_hw / 64.0) / noise_rms
    
    sig_max_amps_rms = max_amps_per_event_rms[signal_mask]
    noise_max_amps_rms = max_amps_per_event_rms[noise_mask]
    
    max_amp_overall_hw = int(np.max(max_amps_per_event_hw))
    max_amp_overall_rms = (max_amp_overall_hw / 64.0) / noise_rms

    thresholds = np.arange(0, max_amp_overall_hw + 1, 1) 
    bin_thresholds_to_test = [4, 6, 8] 
    WINDOW_SIZE = 32

    graphs_eff, graphs_fpr, graphs_roc, graphs_rate, graphs_pur = {}, {}, {}, {}, {}
    colors = {4: ROOT.kBlue, 6: ROOT.kOrange+1, 8: ROOT.kGreen+2}

    print(f"Sweeping {len(thresholds)} individual thresholds with Hi-Lo WINDOW={WINDOW_SIZE}...")
    
    safe_thresholds_hw = {}
    safe_thresholds_rms = {}
    safe_efficiencies = {}
    crossing_stats = {}
    
    for bin_thr in bin_thresholds_to_test:
        eff_vals, fpr_vals, rate_vals, pur_vals, thr_vals = [array.array('d') for _ in range(5)]
        
        # Track independent crossings
        crossing_stats[bin_thr] = {'1CNN': None, '3CNN': None, '4CNN': None}
        found_1cnn = False
        found_3cnn = False
        found_4cnn = False
        
        safe_thr_hw = None
        safe_thr_rms = None
        safe_eff = None
        
        for thresh in thresholds:
            HILO_WINDOW = 5        # Intra-channel gate (e.g., 5 ns)
            COINCIDENCE_WINDOW = 32 # Inter-channel gate (e.g., 32 ns)

            crossed_hi = (X_8ch > thresh)
            crossed_lo = (X_8ch < -thresh)
            
            gates_hi = np.zeros_like(crossed_hi)
            gates_lo = np.zeros_like(crossed_lo)
            
            for shift in range(HILO_WINDOW):
                if shift == 0:
                    gates_hi |= crossed_hi
                    gates_lo |= crossed_lo
                else:
                    gates_hi[:, :, shift:] |= crossed_hi[:, :, :-shift]
                    gates_lo[:, :, shift:] |= crossed_lo[:, :, :-shift]
                    
            bipolar_trigger = gates_hi & gates_lo
            
            coincidence_gates = np.zeros_like(bipolar_trigger)
            
            for shift in range(COINCIDENCE_WINDOW):
                if shift == 0:
                    coincidence_gates |= bipolar_trigger
                else:
                    coincidence_gates[:, :, shift:] |= bipolar_trigger[:, :, :-shift]
            
            multiplicity = np.sum(coincidence_gates, axis=1)
            event_triggered = np.any(multiplicity >= bin_thr, axis=1)
            
            tp = np.sum(event_triggered & signal_mask)
            fp = np.sum(event_triggered & noise_mask)
            tot_trig = tp + fp
            
            tpr = tp / total_signals if total_signals > 0 else 0.0
            fpr = fp / total_noise if total_noise > 0 else 0.0
            trig_rate = tot_trig / total_events if total_events > 0 else 0.0
            purity = tp / tot_trig if tot_trig > 0 else 1.0 
            
            thresh_rms = (thresh / 64.0) / noise_rms
            
            # --- Check 4CNN Limit ---
            if not found_4cnn and trig_rate <= RATE_4CNN:
                crossing_stats[bin_thr]['4CNN'] = {'RMS_Thresh': thresh_rms, 'TPR': tpr, 'FPR': fpr, 'Purity': purity}
                found_4cnn = True

            # --- Check 3CNN Limit ---
            if not found_3cnn and trig_rate <= RATE_3CNN:
                crossing_stats[bin_thr]['3CNN'] = {'RMS_Thresh': thresh_rms, 'TPR': tpr, 'FPR': fpr, 'Purity': purity}
                found_3cnn = True
            
            # --- Check 1CNN Limit (Original Baseline) ---
            if not found_1cnn and trig_rate <= RATE_1CNN:
                safe_thr_hw = thresh
                safe_thr_rms = thresh_rms
                safe_eff = tpr
                found_1cnn = True
                
                crossing_stats[bin_thr]['1CNN'] = {'RMS_Thresh': thresh_rms, 'TPR': tpr, 'FPR': fpr, 'Purity': purity}
                
                # Only log the visual boolean arrays for the strictest (1CNN) requirement to save disk space
                trigger_log_filename = f"optimal_trigger_log_bin{bin_thr}.npy"
                np.save(trigger_log_filename, event_triggered)
                
            eff_vals.append(tpr)
            fpr_vals.append(fpr)
            rate_vals.append(trig_rate)
            pur_vals.append(purity)
            thr_vals.append(thresh_rms)
            
        safe_thresholds_hw[bin_thr] = safe_thr_hw
        safe_thresholds_rms[bin_thr] = safe_thr_rms
        safe_efficiencies[bin_thr] = safe_eff
            
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

    print("Opening ROOT file and saving...")
    ROOT.gROOT.SetBatch(True) 
    root_file = ROOT.TFile(output_root, "RECREATE")
    
    c_hist = ROOT.TCanvas("c_hist", "Amplitude Distributions", 800, 600)
    h_sig = ROOT.TH1F("h_sig", "Max Absolute Amplitude per Event;Maximum Amplitude (Multiples of Noise RMS);Events", 100, 0, max_amp_overall_rms)
    h_noise = ROOT.TH1F("h_noise", "Max Absolute Amplitude per Event", 100, 0, max_amp_overall_rms)
    
    for val in sig_max_amps_rms: h_sig.Fill(val)
    for val in noise_max_amps_rms: h_noise.Fill(val)
        
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
    mg_rate.SetTitle("Total Hi-Lo Trigger Rate vs Threshold")
    for b in bin_thresholds_to_test: mg_rate.Add(graphs_rate[b])
    
    mg_rate.SetMinimum(1e-5)
    mg_rate.Draw("AL")
    
    mg_rate.GetXaxis().SetTitle("Threshold (Multiples of Noise RMS, i.e., SNR)")
    mg_rate.GetYaxis().SetTitle("Total Trigger Rate (Triggers / Total Events)")
    
    # 1CNN Limit
    limit_line = ROOT.TLine(0, RATE_1CNN, max_amp_overall_rms, RATE_1CNN)
    limit_line.SetLineColor(ROOT.kRed)
    limit_line.SetLineStyle(9)
    limit_line.SetLineWidth(2)
    limit_line.Draw("same")

    # 3CNN Limit
    limit_line_3cnn = ROOT.TLine(0, RATE_3CNN, max_amp_overall_rms, RATE_3CNN)
    limit_line_3cnn.SetLineColor(ROOT.kMagenta)
    limit_line_3cnn.SetLineStyle(9)
    limit_line_3cnn.SetLineWidth(2)
    limit_line_3cnn.Draw("same")

    # 4CNN Limit
    limit_line_4cnn = ROOT.TLine(0, RATE_4CNN, max_amp_overall_rms, RATE_4CNN)
    limit_line_4cnn.SetLineColor(ROOT.kBlack)
    limit_line_4cnn.SetLineStyle(9)
    limit_line_4cnn.SetLineWidth(2)
    limit_line_4cnn.Draw("same")
    
    leg_rate = ROOT.TLegend(0.45, 0.55, 0.88, 0.88)
    leg_rate.SetHeader("Multiplicity (BIN_THR)", "C")
    leg_rate.SetBorderSize(1)
    
    for b in bin_thresholds_to_test:
        leg_rate.AddEntry(graphs_rate[b], f"BIN_THR = {b}", "l")
        
        # Draw Crosspoints for 1CNN (1/80)
        stats_1cnn = crossing_stats[b]['1CNN']
        if stats_1cnn is not None:
            st_rms = stats_1cnn['RMS_Thresh']
            vl = ROOT.TLine(st_rms, 1e-5, st_rms, RATE_1CNN)
            vl.SetLineColor(colors[b])
            vl.SetLineStyle(3)
            vl.Draw("same")
            txt = ROOT.TLatex()
            txt.SetTextSize(0.025)
            txt.SetTextColor(colors[b])
            txt.DrawLatex(st_rms + 0.1, RATE_1CNN * 1.5, f"{st_rms:.2f} (1CNN)")

        # Draw Crosspoints for 3CNN (1/26)
        stats_3cnn = crossing_stats[b]['3CNN']
        if stats_3cnn is not None:
            st_rms = stats_3cnn['RMS_Thresh']
            vl = ROOT.TLine(st_rms, 1e-5, st_rms, RATE_3CNN)
            vl.SetLineColor(colors[b])
            vl.SetLineStyle(3)
            vl.Draw("same")
            txt = ROOT.TLatex()
            txt.SetTextSize(0.025)
            txt.SetTextColor(colors[b])
            txt.DrawLatex(st_rms + 0.1, RATE_3CNN * 1.5, f"{st_rms:.2f} (3CNN)")

        # Draw Crosspoints for 4CNN (1/19.5)
        stats_4cnn = crossing_stats[b]['4CNN']
        if stats_4cnn is not None:
            st_rms = stats_4cnn['RMS_Thresh']
            vl = ROOT.TLine(st_rms, 1e-5, st_rms, RATE_4CNN)
            vl.SetLineColor(colors[b])
            vl.SetLineStyle(3)
            vl.Draw("same")
            txt = ROOT.TLatex()
            txt.SetTextSize(0.025)
            txt.SetTextColor(colors[b])
            txt.DrawLatex(st_rms + 0.1, RATE_4CNN * 1.5, f"{st_rms:.2f} (4CNN)")

    leg_rate.AddEntry(limit_line, "1CNN Limit (1/80)", "l")
    leg_rate.AddEntry(limit_line_3cnn, "3CNN Limit (1/26)", "l")
    leg_rate.AddEntry(limit_line_4cnn, "4CNN Limit (1/19.5)", "l")
    leg_rate.Draw()
    ROOT.gPad.SetLogy()
    ROOT.gPad.Modified()
    ROOT.gPad.Update()
    
    c_rate.Write()
    c_rate.Print(output_pdf)

    c_rates = ROOT.TCanvas("c_rates", "Efficiency and FPR", 800, 600)
    mg_rates = ROOT.TMultiGraph()
    mg_rates.SetTitle("Efficiency (Solid) & FPR (Dashed) vs Threshold")
    for b in bin_thresholds_to_test:
        mg_rates.Add(graphs_eff[b])
        mg_rates.Add(graphs_fpr[b])
    mg_rates.Draw("AL")
    
    mg_rates.GetXaxis().SetTitle("Threshold (Multiples of Noise RMS, i.e., SNR)")
    mg_rates.GetYaxis().SetTitle("Rate (0.0 to 1.0)")
    
    leg_rates = ROOT.TLegend(0.55, 0.50, 0.88, 0.88)
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

    c_roc = ROOT.TCanvas("c_roc", "ROC Curve", 800, 600)
    mg_roc = ROOT.TMultiGraph()
    mg_roc.SetTitle("ROC Curve")
    for b in bin_thresholds_to_test: mg_roc.Add(graphs_roc[b])
    mg_roc.Draw("AL")
    
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
    
    c_pur = ROOT.TCanvas("c_pur", "Signal Purity", 800, 600)
    mg_pur = ROOT.TMultiGraph()
    mg_pur.SetTitle("Signal Purity of Triggered Events")
    for b in bin_thresholds_to_test: mg_pur.Add(graphs_pur[b])
    mg_pur.Draw("AL")
    
    mg_pur.GetXaxis().SetTitle("Threshold (Multiples of Noise RMS, i.e., SNR)")
    mg_pur.GetYaxis().SetTitle("Purity (True Positives / Total Triggers)")
    
    leg_pur = ROOT.TLegend(0.65, 0.15, 0.88, 0.35)
    leg_pur.SetBorderSize(1)
    for b in bin_thresholds_to_test:
        leg_pur.AddEntry(graphs_pur[b], f"BIN_THR = {b}", "l")
    leg_pur.Draw()
    ROOT.gPad.Modified()
    ROOT.gPad.Update()
    
    c_pur.Write()
    c_pur.Print(output_pdf)
    
    c_fpr_only = ROOT.TCanvas("c_fpr_only", "FPR vs Threshold", 800, 600)
    mg_fpr_only = ROOT.TMultiGraph()
    mg_fpr_only.SetTitle("False Alarm Rate vs Threshold;Threshold (Multiples of Noise RMS, i.e., SNR);False Alarm Rate (FPR)")
    
    for b in bin_thresholds_to_test: 
        g_clone = graphs_fpr[b].Clone()
        g_clone.SetLineStyle(1) 
        mg_fpr_only.Add(g_clone)
        
    mg_fpr_only.Draw("AL")
    
    mg_fpr_only.SetMinimum(1e-5) 
    mg_fpr_only.SetMaximum(1.0)
    
    leg_fpr_only = ROOT.TLegend(0.65, 0.65, 0.88, 0.88)
    leg_fpr_only.SetBorderSize(1)
    for b in bin_thresholds_to_test:
        leg_fpr_only.AddEntry(graphs_fpr[b], f"BIN_THR = {b}", "l")
    leg_fpr_only.Draw()
    
    ROOT.gPad.SetLogy() 
    ROOT.gPad.Modified()
    ROOT.gPad.Update()
    
    c_fpr_only.Write()
    c_fpr_only.Print(output_pdf + ")")
    
    # --- NEW: Formatted Terminal Output for all limits ---
    print(f"\n{'='*75}")
    print(f"{'CNN LIMIT CROSSING SUMMARY':^75}")
    print(f"{'BIN_THR':<8} | {'Limit':<6} | {'RMS Thresh':<12} | {'TPR (Eff)':<10} | {'FPR':<10} | {'Purity':<10}")
    print(f"{'-'*75}")
    for b in bin_thresholds_to_test:
        # Print from most relaxed limit (4CNN) to strictest limit (1CNN)
        for limit_name in ['4CNN', '3CNN', '1CNN']:
            stats = crossing_stats[b][limit_name]
            if stats:
                print(f"{b:<8} | {limit_name:<6} | {stats['RMS_Thresh']:<12.3f} | {stats['TPR']:<10.4f} | {stats['FPR']:<10.6f} | {stats['Purity']:<10.4f}")
            else:
                print(f"{b:<8} | {limit_name:<6} | {'Never reached limit':<47}")
        print(f"{'-'*75}")
    print(f"{'='*75}\n")

    root_file.Close()
    print(f"Success! Data saved to {output_root}")
    print(f"And compiled into {output_pdf}")

if __name__ == "__main__":
    optimize_trigger_config("X_test_data.npy", "y_test_labels.npy")
        
    try:
        subprocess.run(["python", "viz_continuous_stream.py"], check=True)
    except FileNotFoundError:
        print("Error: Could not find 'viz_continuous_stream.py'. Make sure it exists in the current working directory.")
    except subprocess.CalledProcessError as e:
        print(f"Error: The visualization script crashed with exit code {e.returncode}.")
    except Exception as e:
        print(f"An unexpected error occurred while trying to run the visualization: {e}")