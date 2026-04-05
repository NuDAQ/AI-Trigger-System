import os
from submodule.stimulus_generation import generate_stimulus_file

def main():
    base_dir = os.path.dirname(os.path.abspath(__file__))
    input_data_path = os.path.join(base_dir, "X_test_data.npy")
    output_txt_path = os.path.join(base_dir, "stimulus.txt")
    
    scale = 64.0 
        
    generate_stimulus_file(
        input_npy_path=input_data_path, 
        output_txt_path=output_txt_path,
        scale_factor=scale
    )
    
if __name__ == "__main__":
    main()