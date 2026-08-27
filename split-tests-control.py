#!/usr/bin/env python3
"""Generate debian/tests/control for one container-stack package.

Each package source tree carries the container-stack-tests repo as a git
submodule at debian/tests/container-stack-tests/, with the master control at
debian/tests/container-stack-tests/meta-control. Run from anywhere inside a
package tree; the script walks up to find debian/control, reads the Source:
field, and emits debian/tests/control containing only the stanzas from the
master that depend on that source's binary package.

    # inside ~/pkgs/runc-app/runc-app (or any subdir):
    python3 debian/tests/container-stack-tests/split-tests-control.py

    # explicit overrides:
    python3 split-tests-control.py --package runc-stable
    python3 split-tests-control.py --master /path/to/meta-control --package docker.io-app
    python3 split-tests-control.py -o /tmp/inspect-control   # write elsewhere

Output defaults to debian/tests/control at the detected tree root.
"""

import argparse
import re
import sys
from pathlib import Path

# Binary package names under test.
STACK_BINARIES = (
    'containerd',
    'containerd-stable',
    'docker.io',
    'docker-buildx',
    'docker-compose-v2',
    'runc',
    'runc-stable',
)

# Source package name -> the stack binary its tests must depend on.
# docker.io-app builds both docker.io and docker-doc; tests key on docker.io.
SOURCE_TO_BINARY = {
    'containerd-app': 'containerd',
    'containerd-stable': 'containerd-stable',
    'docker.io-app': 'docker.io',
    'docker-buildx': 'docker-buildx',
    'docker-compose-v2': 'docker-compose-v2',
    'runc-app': 'runc',
    'runc-stable': 'runc-stable',
}

# Submodule mount point within a package tree, and the master control in it.
SUBMODULE_DIR = Path('debian/tests/container-stack-tests')
SUBMODULE_CONTROL = SUBMODULE_DIR / 'meta-control'


def find_source_tree(start: Path):
    """Walk up from start looking for a debian/control; return (root, source)."""
    for directory in (start, *start.parents):
        control = directory / 'debian' / 'control'
        if control.is_file():
            for line in control.read_text().splitlines():
                m = re.match(r'^Source:\s*(\S+)', line)
                if m:
                    return directory, m.group(1)
            return directory, None
    return None, None


def parse_control(text: str):
    """Split control text into stanzas.

    Each stanza: {'comment', 'fields' (name -> value), 'raw' (full text)}.
    """
    lines = text.splitlines()
    stanzas = []
    i = 0
    n = len(lines)

    while i < n:
        while i < n and not lines[i].strip():
            i += 1
        if i >= n:
            break

        comment_lines = []
        while i < n and lines[i].lstrip().startswith('#'):
            comment_lines.append(lines[i])
            i += 1

        while i < n and not lines[i].strip():
            i += 1
        if i >= n:
            break

        fields = {}
        field_lines = []
        current_field = None
        while i < n and lines[i].strip() and not lines[i].lstrip().startswith('#'):
            line = lines[i]
            field_lines.append(line)
            if re.match(r'^\s', line):
                if current_field:
                    fields[current_field] += '\n' + line.strip()
            else:
                m = re.match(r'^([^:]+):\s*(.*)$', line)
                if m:
                    current_field = m.group(1).strip()
                    fields[current_field] = m.group(2).strip()
            i += 1

        stanzas.append({
            'comment': '\n'.join(comment_lines),
            'fields': fields,
            'raw': '\n'.join(comment_lines + field_lines) + '\n',
        })

    return stanzas


def split_depends(depends: str):
    """Package names from a Depends: value (drops alternatives, versions, arch)."""
    pkgs = set()
    for part in depends.split(','):
        part = part.strip()
        if not part:
            continue
        part = part.split('|')[0].strip()
        part = re.split(r'[\s\[\(]', part)[0].strip()
        if part:
            pkgs.add(part)
    return pkgs


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('-p', '--package',
                    help='Source package to generate for (default: detected by '
                         'walking up the tree to the nearest debian/control)')
    ap.add_argument('-m', '--master',
                    help='Path to the master meta-control file (default: '
                         'debian/tests/container-stack-tests/meta-control under '
                         'the detected tree, else the one beside this script)')
    ap.add_argument('-o', '--output',
                    help='Output path (default: debian/tests/control at the tree root)')
    args = ap.parse_args()

    tree_root, detected_source = find_source_tree(Path.cwd().resolve())

    source = args.package or detected_source
    if not source:
        print('error: no debian/control found above cwd; pass --package', file=sys.stderr)
        return 1
    if source not in SOURCE_TO_BINARY:
        print(f'error: {source!r} is not a known container-stack source package',
              file=sys.stderr)
        print(f'known: {", ".join(sorted(SOURCE_TO_BINARY))}', file=sys.stderr)
        return 1
    binary = SOURCE_TO_BINARY[source]

    if args.master:
        master_path = Path(args.master)
    elif tree_root and (tree_root / SUBMODULE_CONTROL).is_file():
        master_path = tree_root / SUBMODULE_CONTROL
    else:
        # Running from the container-stack-tests repo itself.
        master_path = Path(__file__).resolve().parent / 'meta-control'
    if not master_path.is_file():
        print(f'error: master control not found at {master_path}', file=sys.stderr)
        return 1

    if args.output:
        out_path = Path(args.output)
    elif tree_root:
        out_path = tree_root / 'debian' / 'tests' / 'control'
    else:
        out_path = Path(f'{source}-control')

    stanzas = parse_control(master_path.read_text())

    selected = [s for s in stanzas
                if binary in split_depends(s['fields'].get('Depends', ''))
                and binary in STACK_BINARIES]
    if not selected:
        print(f'error: no stanzas in {master_path} depend on {binary}', file=sys.stderr)
        return 1

    body = '\n\n'.join(s['raw'].rstrip() for s in selected) + '\n'

    # Update the test-command in the generated control to target the correct script
    # Tolerates a legacy debian/tests/ prefix in the master too.
    body = re.sub(r'^Test-Command:\s*(?:debian/tests/)?(?:container-stack-tests/)?',
                  'Test-Command: debian/tests/container-stack-tests/',
                  body, flags=re.MULTILINE)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(body)
    print(f'{source} (binary {binary}): wrote {out_path} '
          f'({len(selected)} stanza{"s" if len(selected) != 1 else ""}) '
          f'from {master_path}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
