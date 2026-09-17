#!/usr/bin/env python3
"""Run an isolated Bender-resolved native-IP / actual-XPM system simulation."""
from pathlib import Path
import argparse
import hashlib
import json
import subprocess
import sys
from run_vivado_sim import find_vivado, tcl_quote
from source_manifest import capture

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reference', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--vivado')
    parser.add_argument('--windows', type=int)
    parser.add_argument('--testbench', choices=['tb_native_system','tb_native_modes','tb_native_lane'], default='tb_native_system')
    parser.add_argument('--overload', action='store_true')
    parser.add_argument('--gap', type=int, default=0)
    parser.add_argument('--phase', type=float, default=0)
    parser.add_argument('--threshold', type=lambda x:int(x,0), default=0)
    args = parser.parse_args()
    reference, output = args.reference.resolve(), args.output.resolve()
    metadata = json.loads((reference/'reference.json').read_text())
    for name, digest in metadata['files'].items():
        if hashlib.sha256((reference/name).read_bytes()).hexdigest() != digest:
            parser.error(f'reference hash mismatch: {name}')
    windows = args.windows or metadata['windows']
    if not 1 <= windows <= metadata['windows']:
        parser.error('windows outside supplied reference')
    output.mkdir(parents=True, exist_ok=True)
    capture(ROOT, output, ['vivado', 'simulation'], [ROOT/('tests/'+args.testbench+'.sv'), Path(__file__)])
    files = subprocess.check_output(['bender','script','vivado','-t','vivado','-t','simulation'],cwd=ROOT,text=True)
    (output/'sources.tcl').write_text(files)
    q = tcl_quote
    plusargs = f'-testplusarg REFERENCE={reference} -testplusarg WINDOWS={windows} -testplusarg OVERLOAD={int(args.overload)} -testplusarg GAP={args.gap} -testplusarg PHASE={args.phase} -testplusarg THRESHOLD={args.threshold & 0x1fffff:08x}'
    script = f'''create_project native_system {q(output/'project')} -part xcku5p-ffvb676-2-e -force
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]
set_property XPM_LIBRARIES {{XPM_CDC XPM_MEMORY XPM_FIFO}} [current_project]
source {q(output/'sources.tcl')}
add_files -fileset sim_1 {q(ROOT/('tests/'+args.testbench+'.sv'))}
set_property top {args.testbench} [get_filesets sim_1]
set_property xsim.simulate.runtime all [get_filesets sim_1]
set_property -name xsim.simulate.xsim.more_options -value {q(plusargs)} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
launch_simulation
close_sim
close_project
exit
'''
    (output/'run.tcl').write_text(script)
    command = [find_vivado(args.vivado),'-mode','batch','-source',str(output/'run.tcl'),'-log',str(output/'vivado.log'),'-journal',str(output/'vivado.jou')]
    with (output/'console.log').open('w') as log:
        result = subprocess.run(command,cwd=ROOT,stdout=log,stderr=subprocess.STDOUT)
    logs = list((output/'project').rglob('simulate.log'))
    transcript = '\n'.join(p.read_text(errors='replace') for p in logs)
    if result.returncode or 'PASS native ' not in transcript or 'Fatal:' in transcript:
        print(f'FAIL native simulation; inspect {output}/console.log and project/**/simulate.log',file=sys.stderr)
        return 1
    for line in transcript.splitlines():
        if 'PASS native ' in line: print(line)
    return 0


if __name__ == '__main__':
    sys.exit(main())
