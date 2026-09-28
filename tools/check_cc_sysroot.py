#!/usr/bin/env python3
"""Assert which emsdk sysroot the wasm C/C++ compiles used (labelle-imgui#41).

Reads a `zig build --verbose-cc` log and, for each named source file, collects
the `-isystem` entries that are an emscripten sysroot
(`.../upstream/emscripten/cache/sysroot/include`). Every such entry must be the
expected one: a second SDK's sysroot, even behind the right one, fails.

Usage: check_cc_sysroot.py <log> <expected-sysroot-dir> <source-file>...
Exit 1 naming each file that is missing from the log or saw another sysroot.
"""
import os
import sys

SUFFIX = os.path.join('upstream', 'emscripten', 'cache', 'sysroot', 'include')


def norm(p):
    return os.path.realpath(p.rstrip('/'))


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    log, expected, sources = sys.argv[1], norm(sys.argv[2]), sys.argv[3:]
    lines = open(log, errors='replace').read().splitlines()
    failures = []
    for src in sources:
        cmds = [l for l in lines if (' ' + src + ' ') in l or l.endswith(src) or ('/' + src + ' ') in l]
        if not cmds:
            failures.append(f'{src}: no compile command in the log (was it a cache hit?)')
            continue
        before = len(failures)
        for cmd in cmds:  # every compile of this file must agree
            args = cmd.split()
            sysroots = [args[i + 1] for i, a in enumerate(args[:-1]) if a == '-isystem' and args[i + 1].rstrip('/').endswith(SUFFIX)]
            if not sysroots:
                failures.append(f'{src}: no emscripten sysroot -isystem at all')
            for s in sysroots:
                if norm(s) != expected:
                    failures.append(f'{src}: uses sysroot {s}, expected only {expected}')
        if len(failures) == before:
            print(f'ok: {src} ({len(cmds)} compile(s)) -isystem {expected} only')
    if failures:
        print('\n'.join('FAIL: ' + f for f in failures))
        sys.exit(1)


if __name__ == '__main__':
    main()
