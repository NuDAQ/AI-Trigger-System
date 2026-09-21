#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

python_bin="${PYTHON_BIN:-python3}"
out_dir="${REAL_NOISE_OUT_DIR:-build/real_noise_scan}"
prepare_only="${REAL_NOISE_PREPARE_ONLY:-0}"
analyze_only="${REAL_NOISE_ANALYZE_ONLY:-0}"
adc_vfs_v="${REAL_NOISE_ADC_VFS_V:-0.8}"
cnn_thresh_raw="${REAL_NOISE_CNN_THRESH_RAW:-0}"
project="${REAL_NOISE_PROJECT:-AI_Trigger_System/AI_Trigger_System.xpr}"

for value_name in prepare_only analyze_only; do
    value="${!value_name}"
    if [[ "${value}" != "0" && "${value}" != "1" ]]; then
        echo "ERROR: ${value_name} must be 0 or 1" >&2
        exit 2
    fi
done
if [[ "${prepare_only}" == "1" && "${analyze_only}" == "1" ]]; then
    echo "ERROR: prepare-only and analyze-only cannot both be enabled" >&2
    exit 2
fi

args=(
    --out-dir "${out_dir}"
    --adc-vfs-v "${adc_vfs_v}"
    --cnn-thresh-raw "${cnn_thresh_raw}"
    --project "${project}"
)
if [[ "${prepare_only}" == "1" ]]; then
    args+=(--prepare-only)
elif [[ "${analyze_only}" == "1" ]]; then
    args+=(--analyze-only)
fi
if [[ -n "${REAL_NOISE_VIVADO:-}" ]]; then
    args+=(--vivado "${REAL_NOISE_VIVADO}")
fi

echo "INFO: real-noise scan output: ${out_dir}"
echo "INFO: scope dataset: data/Amp_Scope_Data_3_Offsetted"
echo "INFO: ADC full-scale: ${adc_vfs_v} V; CNN threshold word: ${cnn_thresh_raw} (unit 1/16)"
"${python_bin}" scripts/run_real_noise_scan.py "${args[@]}"
