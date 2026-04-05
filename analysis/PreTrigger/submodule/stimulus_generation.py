import numpy as np
import os

def load_and_preprocess_data(file_path, scale_factor=1.0):
    """Loads the .npy file, scales it, casts to int, and clips to 12-bit."""
    if not os.path.exists(file_path):
        raise FileNotFoundError(f"Cannot find data file: {file_path}")
        
    data = np.load(file_path)
    data = np.squeeze(data) 
    
    data = np.round(data * scale_factor).astype(int)
    
    data = np.clip(data, -2048, 2047)
    
    return data

def format_to_128_int_chunks(data):
    """Flattens data into 128-integer payloads (4 channels * 32 samples) per clock cycle."""
    events, channels, samples = data.shape
    samples_per_clock = 32
    clocks_per_event = samples // samples_per_clock # e.g., 256 / 32 = 8 clocks
    
    formatted_lines = []
    
    for ev in range(events):
        for clk in range(clocks_per_event):
            start_idx = clk * samples_per_clock
            end_idx = start_idx + samples_per_clock
            
            # Extract the 32 samples for all 4 channels in this clock cycle
            # Shape of chunk: (4, 32)
            chunk = data[ev, :, start_idx:end_idx] 
            
            # Flatten to a 1D array of 128 elements 
            # (Ch0_0...Ch0_31, Ch1_0...Ch1_31, etc.)
            flat_chunk = chunk.flatten()
            
            line = " ".join(map(str, flat_chunk))
            formatted_lines.append(line)
            
    return formatted_lines

def generate_stimulus_file(input_npy_path, output_txt_path, scale_factor=1.0):
    """Main submodule pipeline to generate the VHDL stimulus file."""
    print(f"[*] Loading data from {input_npy_path}...")
    raw_data = load_and_preprocess_data(input_npy_path, scale_factor)
    
    print(f"[*] Raw data shape after squeeze: {raw_data.shape}")
    print(f"[*] Data min: {np.min(raw_data)}, max: {np.max(raw_data)} (12-bit bounded)")
    
    print("[*] Formatting data into 128-integer clock cycle payloads...")
    lines = format_to_128_int_chunks(raw_data)
    
    print(f"[*] Writing {len(lines)} lines to {output_txt_path}...")
    with open(output_txt_path, 'w') as f:
        for line in lines:
            f.write(line + "\n")
            
    print("[*] Stimulus generation complete!")