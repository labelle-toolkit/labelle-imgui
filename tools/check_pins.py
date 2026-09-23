#!/usr/bin/env python3
"""Pins that must agree, or a game ends up with two copies of a dependency.

1. Every `.cimgui` pin in this repo is the same revision. Zig keys packages by
   hash, so a mismatch compiles two cimgui artifacts into one game binary.
2. The bgfx bridge's `.zbgfx` pin equals the one in labelle-bgfx's latest
   release. The bridge compiles against its own zbgfx headers but the game
   links the backend's bgfx; when they drifted (bgfx API 142 vs 161, 2026-09-22)
   Flying Platform aborted at startup in createTexture2D. Both repos built
   fine on their own, so only a cross-check like this catches it.

Exit 1 with a message naming each mismatch. Usage: python3 tools/check_pins.py
(set GITHUB_TOKEN to avoid API rate limits).
"""
import glob
import json
import os
import re
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def dep_hash(zon_text, name):
    m = re.search(r'\.' + name + r'\s*=\s*\.\{(.*?)\}', zon_text, re.S)
    if not m:
        return None
    h = re.search(r'\.hash\s*=\s*"([^"]+)"', m.group(1))
    return h.group(1) if h else None


def get(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'labelle-imgui-ci'})
    token = os.environ.get('GITHUB_TOKEN')
    if token and 'api.github.com' in url:
        req.add_header('Authorization', 'Bearer ' + token)
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode()


failures = []

# 1. cimgui pins agree.
cimgui = {}
for path in [os.path.join(ROOT, 'build.zig.zon')] + sorted(glob.glob(os.path.join(ROOT, 'bridges', '*', 'build.zig.zon'))):
    h = dep_hash(open(path).read(), 'cimgui')
    if h:
        cimgui[os.path.relpath(path, ROOT)] = h
if len(set(cimgui.values())) > 1:
    failures.append('cimgui pins disagree:\n' + '\n'.join(f'  {p}: {h}' for p, h in cimgui.items()))
else:
    print(f'ok: {len(cimgui)} cimgui pins agree ({next(iter(cimgui.values()))})')

# 2. bgfx bridge zbgfx == labelle-bgfx latest release.
bridge = dep_hash(open(os.path.join(ROOT, 'bridges', 'bgfx', 'build.zig.zon')).read(), 'zbgfx')
tag = json.loads(get('https://api.github.com/repos/labelle-toolkit/labelle-bgfx/releases/latest'))['tag_name']
backend = dep_hash(get(f'https://raw.githubusercontent.com/labelle-toolkit/labelle-bgfx/{tag}/build.zig.zon'), 'zbgfx')
if bridge != backend:
    failures.append(
        f'bgfx bridge zbgfx pin does not match labelle-bgfx {tag}:\n'
        f'  bridges/bgfx/build.zig.zon: {bridge}\n'
        f'  labelle-bgfx {tag}:        {backend}\n'
        '  A game would compile the bridge against a different bgfx than it links. '
        'Move the bridge pin (and regenerate its shaders if the bgfx API changed).')
else:
    print(f'ok: bgfx bridge zbgfx matches labelle-bgfx {tag} ({bridge})')

if failures:
    print('\n\n'.join(failures), file=sys.stderr)
    sys.exit(1)
