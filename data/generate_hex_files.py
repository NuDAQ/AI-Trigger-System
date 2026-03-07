import numpy as np

def convert_npy_to_hex():
    print("Loading Numpy data...")
    X = np.load('X_test_data.npy')
    y = np.load('y_test_labels.npy')
    
    # Remove the 4th dimension: (1000, 4, 256, 1) -> (1000, 4, 256)
    X = X.squeeze(axis=-1)
    
    print("Writing real_events.hex...")
    with open('real_events.hex', 'w') as f:
        for ev_idx in range(X.shape[0]):
            for t in range(256):
                # Scale amplitude but DO NOT add a baseline.
                # The bitwise AND 0xFFF automatically converts negative Python 
                # integers into perfect 12-bit Two's Complement hex values!
                ch0 = int(X[ev_idx, 0, t] * 64) & 0xFFF
                ch1 = int(X[ev_idx, 1, t] * 64) & 0xFFF
                ch2 = int(X[ev_idx, 2, t] * 64) & 0xFFF
                ch3 = int(X[ev_idx, 3, t] * 64) & 0xFFF
                
                f.write(f"{ch3:03X}{ch2:03X}{ch1:03X}{ch0:03X}\n")

    print("Writing real_labels.hex...")
    with open('real_labels.hex', 'w') as f:
        for ev_idx in range(y.shape[0]):
            f.write(f"{int(y[ev_idx]):08X}\n")
            
    print("Done.")

if __name__ == '__main__':
    convert_npy_to_hex()