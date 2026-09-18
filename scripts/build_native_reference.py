#!/usr/bin/env python3
"""Build ADC-aware native HLS references: the 96 built-ins plus an additive NPZ."""
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess
import numpy as np

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-root', required=True, type=Path)
    parser.add_argument('--npz', required=True, type=Path)
    parser.add_argument('--hls-include', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    core, output = args.core_root.resolve(), args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('output directory must be empty')
    baseline_path = core / 'cnn_core/tb_data/tb_input_features.dat'
    baseline = np.loadtxt(baseline_path, dtype=np.float32)
    with np.load(args.npz, allow_pickle=False) as data:
        x = data['X']
        if x.shape[1:] not in [(256, 4), (256, 4, 1)] or len(x) == 0:
            parser.error('X must contain 256x4 windows')
        x = x.reshape(len(x), 1024)
    if baseline.shape != (96, 1024):
        parser.error('expected all 96 committed reference windows')
    features = np.concatenate([baseline, x]).astype(np.float64)
    if not np.isfinite(features).all():
        parser.error('non-finite model input')
    output.mkdir(parents=True, exist_ok=True)
    # Existing ADC stimulus convention: nearest integer, ties to even. The
    # golden model sees these exact ADC samples, before native quantization.
    raw = np.clip(np.rint(features * 64), -2048, 2047).astype(np.int16)
    (raw.astype('<f4') / 64).tofile(output / 'features.f32')
    with (output / 'adc.hex').open('w') as stream:
        for window in raw.reshape(-1, 256, 4):
            for beat in window.reshape(64, 4, 4):
                # Channels 4..7 retain distinguishable raw data too.
                samples = np.concatenate([beat.T, -beat.T - 1], axis=0)
                word = sum((int(v) & 0xfff) << (12*i) for i, v in enumerate(samples.flat))
                stream.write(f'{word:096x}\n')
    firmware = core / 'cnn_core/firmware'
    shutil.copytree(firmware / 'weights', output / 'weights')
    harness = ROOT / 'scripts/native_reference.cpp'
    command = ['g++', '-std=c++14', '-O2', '-Wno-unknown-pragmas',
               '-I'+str(args.hls_include.resolve()), '-I'+str(firmware),
               str(firmware/'cnn_core.cpp'), str(harness), '-lgmp', '-o', str(output/'native_reference')]
    for name, cmd in [('compile', command), ('csim', [str(output/'native_reference'), str(len(raw))])]:
        with (output/f'{name}.log').open('w') as log:
            result = subprocess.run(cmd, cwd=output, stdout=log, stderr=subprocess.STDOUT)
        if result.returncode:
            raise SystemExit(f'{name} failed; see {output/name}.log')
    words = (output/'all_input.hex').read_text().splitlines()
    scores = (output/'all_expected.hex').read_text().splitlines()
    if len(words) != len(raw)*32 or len(scores) != len(raw):
        raise SystemExit('reference did not produce all windows')
    quantized = np.loadtxt(output/'adc_conversion.txt', dtype=np.int64)
    proposed = np.clip((np.arange(-2048, 2048)+1)//2, -511, 511)
    if not np.array_equal(quantized, proposed):
        raise SystemExit('ADC conversion differs from native fixed-point reference')
    # Fixed centered-window regression inherited from tb_multimode_hilo_ai:
    # positive pulse at beat 67/sample 1, negative at beat 68/sample 0;
    # Hi-Lo anchor beat 69, hence the 64-beat window starts at beat 38.
    gated = output/'gated'
    gated.mkdir()
    stream_raw = np.empty((192, 8, 4), dtype=np.int16)
    for beat in range(192):
        for channel in range(8):
            for sample in range(4):
                stream_raw[beat,channel,sample] = ((beat+channel*7+sample)%32 if channel < 4
                                                   else (beat+channel*256+sample)%2048)
    stream_raw[67,0,1] = 200
    stream_raw[68,0,0] = -200
    centered = stream_raw[38:102,:4,:].transpose(0,2,1).reshape(1,1024)
    (centered.astype('<f4')/64).tofile(gated/'features.f32')
    shutil.copytree(firmware/'weights', gated/'weights')
    with (gated/'adc.hex').open('w') as stream:
        for beat in stream_raw:
            word = sum((int(v)&0xfff)<<(12*i) for i,v in enumerate(beat.flat))
            stream.write(f'{word:096x}\n')
    with (gated/'csim.log').open('w') as log:
        subprocess.run([str(output/'native_reference'),'1'],cwd=gated,stdout=log,stderr=subprocess.STDOUT,check=True)
    manifest = {'windows': len(raw), 'builtin_windows': 96, 'npz_windows': len(x),
                'npz_sha256': sha(args.npz), 'baseline_sha256': sha(baseline_path),
                'adc_scale': 64, 'native_score_scale': 512, 'quantization_codes_checked': 4096,
                'compile_command': command, 'harness_sha256': sha(harness),
                'firmware': {str(p.relative_to(firmware)):sha(p) for p in sorted(firmware.rglob('*')) if p.is_file()},
                'files': {n:sha(output/n) for n in ['adc.hex','all_input.hex','all_expected.hex','adc_conversion.txt','gated/adc.hex','gated/all_expected.hex']}}
    (output/'reference.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print(f'PASS ADC-aware reference: {len(raw)} windows; 4096 native ADC conversions')


if __name__ == '__main__':
    main()
