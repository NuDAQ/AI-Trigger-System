import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
from matplotlib.backends.backend_pdf import PdfPages

def generate_continuous_pdf(data_path, labels_path, trigger_path=None, output_pdf="viz_continuous_waveform.pdf", chunks_per_page=10):
    print(f"Loading data from {data_path} and {labels_path}...")
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    num_events, num_channels, chunk_size = X_test.shape
    total_samples = num_events * chunk_size

    if trigger_path:
        trigger_results = np.load(trigger_path)
    else:
        print("[Warning] No trigger data provided. Generating mock trigger results for visualization.")
        trigger_results = np.random.choice([0, 1], size=(num_events,), p=[0.9, 0.1])

    with PdfPages(output_pdf) as pdf:
        num_pages = int(np.ceil(num_events / chunks_per_page))
        
        for page in range(num_pages):
            start_chunk = page * chunks_per_page
            end_chunk = min(start_chunk + chunks_per_page, num_events)
            
            fig, axes = plt.subplots(num_channels, 1, figsize=(20, 10), sharex=True)
            if num_channels == 1:
                axes = [axes]

            patch_tn = mpatches.Patch(color='white', ec='black', label='Noise, Not Triggered')
            patch_fn = mpatches.Patch(color='red', alpha=0.2, label='Signal, Missed')
            patch_fp = mpatches.Patch(color='blue', alpha=0.2, label='Noise, False Alarm')
            patch_tp = mpatches.Patch(color='green', alpha=0.2, label='Signal, Hit')

            fig.legend(handles=[patch_tn, patch_fn, patch_fp, patch_tp], 
                       loc='upper center', ncol=4, fontsize=12, bbox_to_anchor=(0.5, 0.98))
            
            fig.subplots_adjust(top=0.88)
            fig.suptitle(f"Trigger System Evaluation (Chunks {start_chunk} to {end_chunk - 1})", fontsize=16, y=0.92)

            page_start_time = start_chunk * chunk_size
            page_end_time = end_chunk * chunk_size
            
            for ch in range(num_channels):
                ax = axes[ch]
                ax.set_ylabel(f"Channel {ch}")
                
                ch_data = X_test[start_chunk:end_chunk, ch, :].flatten()
                time_axis = np.arange(page_start_time, page_end_time)
                ax.plot(time_axis, ch_data, color='black', linewidth=0.8)

                for i in range(start_chunk, end_chunk):
                    chunk_start_time = i * chunk_size
                    
                    ax.axvline(x=chunk_start_time, color='gray', linestyle='--', alpha=0.5, linewidth=1)
                    
                    is_signal = (y_test[i] == 1)
                    is_triggered = (trigger_results[i] == 1)
                    
                    color = None
                    if is_signal and not is_triggered:
                        color = 'red'     # Miss
                    elif not is_signal and is_triggered:
                        color = 'blue'    # False Alarm
                    elif is_signal and is_triggered:
                        color = 'green'   # Successful Hit

                    if color:
                        ax.axvspan(chunk_start_time, chunk_start_time + chunk_size, color=color, alpha=0.2)
            
            axes[-1].set_xlabel("Continuous Time (ns)")
            axes[-1].set_xlim(page_start_time, page_end_time)
            
            pdf.savefig(fig)
            plt.close(fig)
            
            if (page + 1) % 10 == 0:
                print(f"Generated {page + 1}/{num_pages} pages")

    print(f"Saved continuous stream to {output_pdf}")

if __name__ == "__main__":
    DATA_NPY = "X_test_data.npy"
    LABELS_NPY = "y_test_labels.npy"
    TRIGGER_NPY = None 
    OUTPUT_PDF = "viz_continuous_waveform.pdf"
    
    generate_continuous_pdf(DATA_NPY, LABELS_NPY, trigger_path=TRIGGER_NPY, output_pdf=OUTPUT_PDF, chunks_per_page=10)