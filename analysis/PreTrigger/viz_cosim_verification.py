import os
import numpy as np
import array
import ROOT

def verify_cosimulation(data_path, labels_path, output_root="cosim_verification.root", output_pdf="cosim_verification_report.pdf"):
    print(f"Loading data from {data_path}...")
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    # Clean shape: (1000, 4, 256)
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    signal_mask = (y_test == 1)
    noise_mask = (y_test == 0)
    
    total_signals = np.sum(signal_mask)
    total_noise = np.sum(noise_mask)
    total_events = total_signals + total_noise

    pure_noise_waveforms = X_test[noise_mask]
    noise_rms = np.std(pure_noise_waveforms)
    print(f"Calculated Background Noise RMS: {noise_rms:.6f}")

    X_int = (X_test * 64).astype(np.int32)
    
    max_amps_per_event_hw = np.max(np.abs(X_int), axis=(1, 2))
    max_amp_overall_hw = int(np.max(max_amps_per_event_hw))
    
    max_amps_per_event_rms = (max_amps_per_event_hw / 64.0) / noise_rms
    sig_max_amps_rms = max_amps_per_event_rms[signal_mask]
    noise_max_amps_rms = max_amps_per_event_rms[noise_mask]
    max_amp_overall_rms = (max_amp_overall_hw / 64.0) / noise_rms
    
    hw_thresholds_int = [128, 160, 192, 224, 256, 288, 320]
    
    hw_thr_rms_vals = array.array('d')
    hw_eff_vals = array.array('d')
    hw_fpr_vals = array.array('d')
    hw_rate_vals = array.array('d')

    print(" HARDWARE LOG EXTRACTION ")
    print(f"{'Int Thr':<8} | {'RMS Thr':<8} | {'TPR (Eff)':<10} | {'FPR':<10} | {'Total Rate':<10}")
    print("-" * 60)

    for hw_thr in hw_thresholds_int:
        log_file = f"hw_resp_thr_{hw_thr}.txt"
        if not os.path.exists(log_file):
            print(f"WARNING: {log_file} not found. Skipping this hardware point.")
            continue
            
        raw_hw_resp = np.loadtxt(log_file, dtype=int)
        aligned_hw_resp = raw_hw_resp[2:]
        
        if len(aligned_hw_resp) > 8000:
            aligned_hw_resp = aligned_hw_resp[:8000]
            
        hw_events = aligned_hw_resp.reshape(total_events, 8)
        
        event_triggered_hw = np.any(hw_events == 1, axis=1)
        
        tp_hw = np.sum(event_triggered_hw & signal_mask)
        fp_hw = np.sum(event_triggered_hw & noise_mask)
        tot_trig_hw = tp_hw + fp_hw
        
        tpr_hw = tp_hw / total_signals if total_signals > 0 else 0.0
        fpr_hw = fp_hw / total_noise if total_noise > 0 else 0.0
        rate_hw = tot_trig_hw / total_events if total_events > 0 else 0.0
        thr_rms_hw = hw_thr / (64.0 * noise_rms)
        
        hw_thr_rms_vals.append(thr_rms_hw)
        hw_eff_vals.append(tpr_hw)
        hw_fpr_vals.append(fpr_hw)
        hw_rate_vals.append(rate_hw)
        
        print(f"{hw_thr:<8} | {thr_rms_hw:<8.2f} | {tpr_hw:<10.4f} | {fpr_hw:<10.6f} | {rate_hw:<10.6f}")
    
    thresholds_to_sweep = np.arange(0, min(max_amp_overall_hw + 1, 400), 1) 
    
    py_thr_rms_vals = array.array('d')
    py_eff_vals = array.array('d')
    py_fpr_vals = array.array('d')
    py_rate_vals = array.array('d')
    
    BIN_THR = 2             # Strict N=2 Coincidence
    HILO_WINDOW = 5         # Intra-channel gate (5 ns)
    COINCIDENCE_WINDOW = 32 # Inter-channel gate (32 ns)

    for thresh in thresholds_to_sweep:
        crossed_hi = (X_int > thresh)
        crossed_lo = (X_int < -thresh)
        
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
        event_triggered = np.any(multiplicity >= BIN_THR, axis=1)
        
        tp = np.sum(event_triggered & signal_mask)
        fp = np.sum(event_triggered & noise_mask)
        tot_trig = tp + fp
        
        tpr = tp / total_signals if total_signals > 0 else 0.0
        fpr = fp / total_noise if total_noise > 0 else 0.0
        trig_rate = tot_trig / total_events if total_events > 0 else 0.0
        thresh_rms = (thresh / 64.0) / noise_rms
        
        py_thr_rms_vals.append(thresh_rms)
        py_eff_vals.append(tpr)
        py_fpr_vals.append(fpr)
        py_rate_vals.append(trig_rate)

    print(f"Completed {len(thresholds_to_sweep)} threshold emulation steps.")

    print("\nOpening ROOT file and generating overlay plots...")
    ROOT.gROOT.SetBatch(True) 
    root_file = ROOT.TFile(output_root, "RECREATE")
    
    g_py_eff = ROOT.TGraph(len(py_thr_rms_vals), py_thr_rms_vals, py_eff_vals)
    g_py_eff.SetLineColor(ROOT.kBlue)
    g_py_eff.SetLineWidth(2)
    
    g_py_fpr = ROOT.TGraph(len(py_thr_rms_vals), py_thr_rms_vals, py_fpr_vals)
    g_py_fpr.SetLineColor(ROOT.kBlue)
    g_py_fpr.SetLineStyle(2)
    g_py_fpr.SetLineWidth(2)
    
    g_py_rate = ROOT.TGraph(len(py_thr_rms_vals), py_thr_rms_vals, py_rate_vals)
    g_py_rate.SetLineColor(ROOT.kBlack)
    g_py_rate.SetLineWidth(2)
    
    g_py_roc = ROOT.TGraph(len(py_fpr_vals), py_fpr_vals, py_eff_vals)
    g_py_roc.SetLineColor(ROOT.kBlack)
    g_py_roc.SetLineWidth(2)

    marker_style = 29 # ROOT.kFullStar
    marker_size = 2.5
    marker_color = ROOT.kRed

    g_hw_eff = ROOT.TGraph(len(hw_thr_rms_vals), hw_thr_rms_vals, hw_eff_vals)
    g_hw_eff.SetMarkerStyle(marker_style)
    g_hw_eff.SetMarkerSize(marker_size)
    g_hw_eff.SetMarkerColor(marker_color)
    
    g_hw_fpr = ROOT.TGraph(len(hw_thr_rms_vals), hw_thr_rms_vals, hw_fpr_vals)
    g_hw_fpr.SetMarkerStyle(marker_style)
    g_hw_fpr.SetMarkerSize(marker_size)
    g_hw_fpr.SetMarkerColor(marker_color)
    
    g_hw_rate = ROOT.TGraph(len(hw_thr_rms_vals), hw_thr_rms_vals, hw_rate_vals)
    g_hw_rate.SetMarkerStyle(marker_style)
    g_hw_rate.SetMarkerSize(marker_size)
    g_hw_rate.SetMarkerColor(marker_color)
    
    g_hw_roc = ROOT.TGraph(len(hw_fpr_vals), hw_fpr_vals, hw_eff_vals)
    g_hw_roc.SetMarkerStyle(marker_style)
    g_hw_roc.SetMarkerSize(marker_size)
    g_hw_roc.SetMarkerColor(marker_color)

    # --- Canvas 1: Amplitude Distributions ---
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

    # --- Canvas 2: Rate vs Threshold ---
    c_rate = ROOT.TCanvas("c_rate", "Total Trigger Rate", 800, 600)
    mg_rate = ROOT.TMultiGraph()
    mg_rate.SetTitle("Co-Simulation Verification: Total Trigger Rate;Threshold (SNR);Total Rate")
    mg_rate.Add(g_py_rate, "L")
    mg_rate.Add(g_hw_rate, "P") # P for points
    mg_rate.Draw("A")
    mg_rate.SetMinimum(1e-5)
    
    leg_rate = ROOT.TLegend(0.55, 0.65, 0.88, 0.85)
    leg_rate.SetBorderSize(1)
    leg_rate.AddEntry(g_py_rate, "Python Emulation (Line)", "l")
    leg_rate.AddEntry(g_hw_rate, "VHDL Simulation (Stars)", "p")
    leg_rate.Draw()
    
    ROOT.gPad.SetLogy()
    c_rate.Write()
    c_rate.Print(output_pdf) # Appends to PDF

    # --- Canvas 3: Eff & FPR vs Threshold ---
    c_rates = ROOT.TCanvas("c_rates", "Efficiency and FPR", 800, 600)
    mg_rates = ROOT.TMultiGraph()
    mg_rates.SetTitle("Co-Simulation Verification: TPR & FPR;Threshold (SNR);Rate (0.0 to 1.0)")
    
    mg_rates.Add(g_py_eff, "L")
    mg_rates.Add(g_py_fpr, "L")
    mg_rates.Add(g_hw_eff, "P")
    mg_rates.Add(g_hw_fpr, "P")
    mg_rates.Draw("A")
    
    leg_rates = ROOT.TLegend(0.55, 0.55, 0.88, 0.85)
    leg_rates.SetBorderSize(1)
    leg_rates.AddEntry(g_py_eff, "Python Eff (Solid)", "l")
    leg_rates.AddEntry(g_py_fpr, "Python FPR (Dashed)", "l")
    leg_rates.AddEntry(g_hw_eff, "VHDL Eff/FPR (Stars)", "p")
    leg_rates.Draw()
    
    c_rates.Write()
    c_rates.Print(output_pdf) # Appends to PDF

    # --- Canvas 4: ROC Curve ---
    c_roc = ROOT.TCanvas("c_roc", "ROC Curve", 800, 600)
    mg_roc = ROOT.TMultiGraph()
    mg_roc.SetTitle("Co-Simulation Verification: ROC Curve;False Alarm Rate (FPR);Trigger Efficiency (TPR)")
    
    mg_roc.Add(g_py_roc, "L")
    mg_roc.Add(g_hw_roc, "P")
    mg_roc.Draw("A")
    ROOT.gPad.SetLogx()
    
    leg_roc = ROOT.TLegend(0.55, 0.20, 0.88, 0.40)
    leg_roc.SetBorderSize(1)
    leg_roc.AddEntry(g_py_roc, "Python Emulation", "l")
    leg_roc.AddEntry(g_hw_roc, "VHDL Simulation", "p")
    leg_roc.Draw()
    
    c_roc.Write()
    c_roc.Print(output_pdf + ")")

    root_file.Close()
    print(f"\nSuccess! Co-simulation output saved to {output_root} and compiled into {output_pdf}")

if __name__ == "__main__":
    verify_cosimulation("X_test_data.npy", "y_test_labels.npy")