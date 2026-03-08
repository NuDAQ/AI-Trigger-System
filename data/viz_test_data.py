import numpy as np
import ROOT
import os

def generate_root_visualizations(data_path, labels_path, output_root_file, num_events_to_plot=10):
    # 1. Load the data
    print(f"Loading data from {data_path} and {labels_path}...")
    try:
        X_test = np.load(data_path)
        y_test = np.load(labels_path)
    except FileNotFoundError as e:
        print(f"Error loading files: {e}")
        return

    # (N, 4, 256, 1) -> (N, 4, 256)
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    num_events, num_channels, num_samples = X_test.shape
    print(f"Loaded {num_events} events. Each has {num_channels} channels with {num_samples} samples.")

    root_file = ROOT.TFile(output_root_file, "RECREATE")
    if root_file.IsZombie():
        print(f"Error: Could not create {output_root_file}")
        return

    print(f"Creating visualizations for the first {num_events_to_plot} events...")

    # Time array (x-axis): 0 to 255
    time_steps = np.arange(num_samples, dtype=np.float64)

    for i in range(min(num_events, num_events_to_plot)):
        label = int(y_test[i])
        class_name = "Neutrino Signal" if label == 1 else "Background Noise"
        
        canvas_name = f"Event_{i}_Label_{label}"
        canvas_title = f"Event {i} - {class_name}"
        c = ROOT.TCanvas(canvas_name, canvas_title, 1200, 800)
        c.Divide(2, 2) # Divide into 2x2 grid for 4 channels

        graphs = [] 
        for ch in range(num_channels):
            c.cd(ch + 1) # Switch to the specific pad (pads are 1-indexed)
            
            amplitudes = np.array(X_test[i, ch, :], dtype=np.float64)
            
            graph = ROOT.TGraph(num_samples, time_steps, amplitudes)
            graph.SetTitle(f"Channel {ch}; Time Step; Amplitude")
            graph.SetLineColor(ROOT.kBlue + 2)
            graph.SetLineWidth(2)
            
            graph.Draw("AL")
            
            ROOT.gPad.SetGridx()
            ROOT.gPad.SetGridy()
            
            graphs.append(graph)

        root_file.cd()
        c.Write()

    root_file.Close()
    print(f"Successfully saved {num_events_to_plot} event visualizations to {output_root_file}.")

if __name__ == "__main__":
    DATA_NPY = "X_test_data.npy"
    LABELS_NPY = "y_test_labels.npy"
    OUTPUT_ROOT = "testdata_viz.root"
    
    generate_root_visualizations(DATA_NPY, LABELS_NPY, OUTPUT_ROOT, num_events_to_plot=20)