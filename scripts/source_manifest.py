#!/usr/bin/env python3
"""Record the exact Bender source closure used by a build or simulation."""
from pathlib import Path
import hashlib
import json
import subprocess


def capture(root: Path, output: Path, targets: list[str], extras: list[Path] = (), bender: str = 'bender') -> None:
    command = [bender, 'sources', '-f']
    for target in targets:
        command += ['-t', target]
    groups = json.loads(subprocess.check_output(command, cwd=root, text=True))
    files = []
    for group in groups:
        for filename in group['files']:
            path = Path(filename)
            files.append({'package': group['package'], 'file': path.name,
                          'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                          'resolved_path': str(path)})
    for path in extras:
        files.append({'package': 'validation', 'file': path.name,
                      'sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                      'resolved_path': str(path)})
    (output/'source_manifest.json').write_text(json.dumps({'targets':targets,'files':files},indent=2)+'\n')
