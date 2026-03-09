import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.backends.backend_pdf import PdfPages

def generate_continuous_pdf(data_path, labels_path, trigger_path=None, output_pdf="continuous_trigger_evaluation.pdf", chunks_per_page=10):
    # 1. Load Data
    print(f"Loading data from {data_path} and {labels_path}...")
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    pure_noise = X_test[y_test == 0]
    
    noise_rms = np.std(pure_noise)
    print(f"Calculated Background Noise RMS: {noise_rms:.6f}")
    
    X_test = X_test / noise_rms

    num_events, num_channels, chunk_size = X_test.shape
    total_samples = num_events * chunk_size
    print(f"Loaded {num_events} chunks. Total continuous time: {total_samples} ns.")

    # --- Load or Mock Hardware Trigger Data ---
    if trigger_path:
        # Load your actual hardware results here later
        trigger_results = np.load(trigger_path)
        print(f"Loaded trigger results from {trigger_path}")
    else:
        # DUMMY DATA: Randomly triggering 10% of the time to visualize the legend
        print("No trigger data provided. Generating mock trigger results for visualization...")
        trigger_results = np.random.choice([0, 1], size=(num_events,), p=[0.9, 0.1])

    # 2. Open multi-page PDF
    print(f"Generating PDF: {output_pdf}")
    with PdfPages(output_pdf) as pdf:
        num_pages = int(np.ceil(num_events / chunks_per_page))
        
        for page in range(num_pages):
            start_chunk = page * chunks_per_page
            end_chunk = min(start_chunk + chunks_per_page, num_events)
            
            # Create a wide figure (20x10 inches)
            fig, axes = plt.subplots(num_channels, 1, figsize=(20, 10), sharex=True)
            if num_channels == 1:
                axes = [axes]

            # --- Create Custom Legend Handles ---
            patch_tn = mpatches.Patch(color='white', ec='black', label='Noise, Not Triggered (White)')
            patch_fn = mpatches.Patch(color='red', alpha=0.2, label='Signal, Missed (Red)')
            patch_fp = mpatches.Patch(color='blue', alpha=0.2, label='Noise, False Alarm (Blue)')
            patch_tp = mpatches.Patch(color='green', alpha=0.2, label='Signal, Hit (Green)')

            # Add the legend to the top center of the figure
            fig.legend(handles=[patch_tn, patch_fn, patch_fp, patch_tp], 
                       loc='upper center', ncol=4, fontsize=12, bbox_to_anchor=(0.5, 0.98))
            
            # Adjust the top margin so the title and legend don't overlap
            fig.subplots_adjust(top=0.88)
            fig.suptitle(f"Trigger System Evaluation (Chunks {start_chunk} to {end_chunk - 1})", fontsize=16, y=0.92)

            page_start_time = start_chunk * chunk_size
            page_end_time = end_chunk * chunk_size
            
            for ch in range(num_channels):
                ax = axes[ch]
                ax.set_ylabel(f"Ch {ch}\n(Amplitude / RMS)")
                
                # Plot the continuous waveform for this page
                ch_data = X_test[start_chunk:end_chunk, ch, :].flatten()
                time_axis = np.arange(page_start_time, page_end_time)
                ax.plot(time_axis, ch_data, color='black', linewidth=0.8)

                for i in range(start_chunk, end_chunk):
                    chunk_start_time = i * chunk_size
                    
                    # Demarcation line every 256 samples
                    ax.axvline(x=chunk_start_time, color='gray', linestyle='--', alpha=0.5, linewidth=1)
                    
                    # Determine background color based on Truth (y_test) and Prediction (trigger_results)
                    is_signal = (y_test[i] == 1)
                    is_triggered = (trigger_results[i] == 1)
                    
                    color = None
                    if is_signal and not is_triggered:
                        color = 'red'     # Miss (False Negative)
                    elif not is_signal and is_triggered:
                        color = 'blue'    # False Alarm (False Positive)
                    elif is_signal and is_triggered:
                        color = 'green'   # Successful Hit (True Positive)
                    # If white (Noise, Not Triggered), we leave it blank

                    if color:
                        ax.axvspan(chunk_start_time, chunk_start_time + chunk_size, color=color, alpha=0.2)
            
            axes[-1].set_xlabel("Continuous Time (ns)")
            axes[-1].set_xlim(page_start_time, page_end_time)
            
            # Adjust layout and save to PDF
            plt.tight_layout(rect=[0, 0, 1, 0.88]) 
            pdf.savefig(fig)
            plt.close(fig)
            
            if (page + 1) % 10 == 0 or (page + 1) == num_pages:
                print(f"Generated {page + 1}/{num_pages} pages...")

    print(f"Successfully saved continuous stream to {output_pdf}")

if __name__ == "__main__":
    DATA_NPY = "X_test_data.npy"
    LABELS_NPY = "y_test_labels.npy"
    
    # Set this to the actual path of your trigger results array later:
    TRIGGER_NPY = None 
    OUTPUT_PDF = "continuous_trigger_evaluation.pdf"
    
    generate_continuous_pdf(DATA_NPY, LABELS_NPY, trigger_path=TRIGGER_NPY, output_pdf=OUTPUT_PDF, chunks_per_page=10)