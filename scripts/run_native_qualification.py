#!/usr/bin/env python3
"""Run the native system qualification cases with compact per-case logs."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CASES = {
    'continuous': [],
    'gaps': ['--gap','9','--phase','1.3'],
    'lane-reset': ['--testbench','tb_native_lane'],
    'modes': ['--testbench','tb_native_modes'],
    'overload': ['--overload'],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--vivado')
    parser.add_argument('--cases', nargs='+', choices=list(CASES), default=list(CASES))
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('qualification output directory must be empty')
    output.mkdir(parents=True, exist_ok=True)
    results = []
    for name in args.cases:
        command = [sys.executable,str(ROOT/'scripts/run_native_sim.py'),
                   '--reference',str(args.reference.resolve()),'--output',str(output/name),*CASES[name]]
        if args.vivado:
            command += ['--vivado',args.vivado]
        completed = subprocess.run(command,cwd=ROOT,capture_output=True,text=True)
        (output/f'{name}.log').write_text(completed.stdout+completed.stderr)
        results.append({'case':name,'passed':completed.returncode==0,'command':command,
                        'summary':completed.stdout.strip(),'error':completed.stderr.strip()})
        (output/'summary.json').write_text(json.dumps({'passed':all(r['passed'] for r in results),
                                                      'complete':len(results)==len(args.cases),
                                                      'results':results},indent=2)+'\n')
        print(f'{"PASS" if completed.returncode==0 else "FAIL"} {name}: {completed.stdout.strip()}',flush=True)
        if completed.returncode:
            return completed.returncode
    return 0


if __name__ == '__main__':
    sys.exit(main())
