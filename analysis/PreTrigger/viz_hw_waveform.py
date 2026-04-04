import sys
import numpy as np
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
from vcdvcd import VCDVCD

def generate_hw_waveform_pdf(vcd_path, output_pdf="hardware_waveform_report.pdf"):
    print(f"Parsing Hardware Simulation VCD: {vcd_path}...")
    try:
        vcd = VCDVCD(vcd_path)
    except FileNotFoundError:
        print(f"Error: Could not find {vcd_path}. Run fst2vcd first.")
        sys.exit(1)
    
    target_signals = [
        'tb_pre_trigger.clk',
        'tb_pre_trigger.reset',
        'tb_pre_trigger.data_str',
        'tb_pre_trigger.pre_trig'
    ]
    
    signal_data = {}
    max_time = 0
    
    # Extract temporal data for each signal
    for sig in target_signals:
        if sig in vcd.references_to_ids:
            tv = vcd[sig].tv
            times = []
            vals = []
            
            for t, v in tv:
                times.append(t / 1000000.0)
                # Map standard binary states. Uninitialized ('U') states map to 0 for graphing.
                if v == '1':
                    vals.append(1)
                else:
                    vals.append(0)
            
            signal_data[sig] = (times, vals)
            if times:
                max_time = max(max_time, times[-1])
        else:
            print(f"Warning: Signal '{sig}' not found in VCD hierarchy.")

    if not signal_data:
        print("No valid signals extracted. Exiting.")
        sys.exit(1)

    print(f"Generating PDF: {output_pdf}")
    with PdfPages(output_pdf) as pdf:
        # Create a stacked subplot architecture
        fig, axes = plt.subplots(len(signal_data), 1, figsize=(16, 10), sharex=True)
        if len(signal_data) == 1:
            axes = [axes]
            
        fig.suptitle("Hardware Trigger Pipeline: VHDL Simulation Output", fontsize=16, y=0.95)
        
        colors = ['black', 'red', 'blue', 'green']
        
        for i, (sig_name, ax) in enumerate(zip(signal_data.keys(), axes)):
            times, vals = signal_data[sig_name]
            
            # Extend the final state to the absolute end of the simulation timeline
            if len(times) > 0 and times[-1] < max_time:
                times.append(max_time)
                vals.append(vals[-1])
            
            # Use 'post' step plotting for accurate digital timing representation
            ax.step(times, vals, where='post', color=colors[i % len(colors)], linewidth=2)
            
            # Formatting
            clean_name = sig_name.split('.')[-1]
            ax.set_ylabel(clean_name, rotation=0, labelpad=40, ha='right', fontsize=14, fontweight='bold')
            ax.set_ylim(-0.2, 1.2)
            ax.set_yticks([0, 1])
            ax.grid(True, which='both', linestyle='--', alpha=0.6)
            
            # Highlight the PRE_TRIG assertions
            if clean_name == 'PRE_TRIG':
                ax.fill_between(times, vals, step="post", color='green', alpha=0.2)
            
        axes[-1].set_xlabel("Simulation Time (ns)", fontsize=14)
        axes[-1].set_xlim(380, 460)
        
        plt.tight_layout(rect=[0, 0.03, 1, 0.92])
        pdf.savefig(fig)
        plt.close(fig)
        
    print(f"Success! Hardware waveform plotted to {output_pdf}")

if __name__ == "__main__":
    VCD_PATH = "../../HDL/PreTrigger/sim/wave_top.vcd"
    
    PDF_OUT = "hardware_waveform_report.pdf"
    
    generate_hw_waveform_pdf(VCD_PATH, PDF_OUT)