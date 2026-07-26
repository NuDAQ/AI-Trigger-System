#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/.." && pwd)"
cd "${repo_root}"

python_bin="${PYTHON_BIN:-python3}"
out_dir="${BRINGUP_OUT_DIR:-build/bringup_sim}"
generate_only="${BRINGUP_GENERATE_ONLY:-0}"

if [[ "${generate_only}" != "0" && "${generate_only}" != "1" ]]; then
    echo "ERROR: BRINGUP_GENERATE_ONLY must be 0 or 1" >&2
    exit 2
fi

echo "INFO: output root: ${out_dir}"
echo "INFO: pulse cases: bipolar_sweep, polar_sweep, monopolar_100mv_100ns_sweep,"
echo "INFO:              monopolar_100mv_100ns_erf_tr100ns_sweep,"
echo "INFO:              monopolar_50mv_50ns_erf_tr50ns_sweep,"
echo "INFO:              monopolar_10mv_10ns_erf_tr10ns_sweep"

runner_args=(
    --stimulus all
    --out-dir "${out_dir}"
)
if [[ "${generate_only}" == "1" ]]; then
    runner_args+=(--generate-only)
fi

"${python_bin}" scripts/run_bringup_sim.py "${runner_args[@]}"

if [[ "${generate_only}" == "1" ]]; then
    echo "INFO: generate-only: skipping score plotting"
    exit 0
fi

"${python_bin}" scripts/plot_bringup_scores.py --out-dir "${out_dir}"
