import numpy as np
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

def generate_continuous_pdf(data_path, labels_path, output_pdf, chunks_per_page=10):
    # 1. Load Data
    print(f"Loading data from {data_path} and {labels_path}...")
    X_test = np.load(data_path)
    y_test = np.load(labels_path)
    
    if len(X_test.shape) == 4 and X_test.shape[-1] == 1:
        X_test = np.squeeze(X_test, axis=-1)

    num_events, num_channels, chunk_size = X_test.shape
    total_samples = num_events * chunk_size
    print(f"Loaded {num_events} chunks. Total continuous time: {total_samples} ns.")

    # 2. Open multi-page PDF
    with PdfPages(output_pdf) as pdf:
        num_pages = int(np.ceil(num_events / chunks_per_page))
        
        for page in range(num_pages):
            start_chunk = page * chunks_per_page
            end_chunk = min(start_chunk + chunks_per_page, num_events)
            
            # Create a wide figure (e.g., 20 inches wide by 10 inches tall)
            fig, axes = plt.subplots(num_channels, 1, figsize=(20, 10), sharex=True)
            if num_channels == 1:
                axes = [axes]
                
            fig.suptitle(f"Continuous Data Stream (Chunks {start_chunk} to {end_chunk - 1})", fontsize=16)

            # Keep track of the continuous time for this specific page
            page_start_time = start_chunk * chunk_size
            page_end_time = end_chunk * chunk_size
            
            for ch in range(num_channels):
                ax = axes[ch]
                ax.set_ylabel(f"Channel {ch}")
                
                # Plot the concatenated waveform for this page
                ch_data = X_test[start_chunk:end_chunk, ch, :].flatten()
                time_axis = np.arange(page_start_time, page_end_time)
                ax.plot(time_axis, ch_data, color='black', linewidth=0.8)

                # Process chunk boundaries and backgrounds
                for i in range(start_chunk, end_chunk):
                    chunk_start_time = i * chunk_size
                    
                    # Draw short vertical line for demarcation
                    ax.axvline(x=chunk_start_time, color='blue', linestyle='--', alpha=0.5, linewidth=1)
                    
                    # Highlight background if it is a signal event
                    if y_test[i] == 1:
                        ax.axvspan(chunk_start_time, chunk_start_time + chunk_size, 
                                   color='red', alpha=0.2, label='Neutrino Signal' if i == start_chunk else "")
            
            axes[-1].set_xlabel("Continuous Time (ns)")
            axes[-1].set_xlim(page_start_time, page_end_time)
            
            # Adjust layout and save the page
            plt.tight_layout()
            pdf.savefig(fig)
            plt.close(fig)
            
            if (page + 1) % 10 == 0:
                print(f"Generated {page + 1}/{num_pages} pages...")

    print(f"Successfully saved continuous stream to {output_pdf}")

if __name__ == "__main__":
    DATA_NPY = "X_test_data.npy"
    LABELS_NPY = "y_test_labels.npy"
    OUTPUT_PDF = "continuous_waveform_stream.pdf"
    
    # 10 chunks per page means 2,560 ns wide. You can increase this to see more time at once.
    generate_continuous_pdf(DATA_NPY, LABELS_NPY, OUTPUT_PDF, chunks_per_page=10)