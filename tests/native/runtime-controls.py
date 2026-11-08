# SPDX-License-Identifier: MIT
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


def probe(root, value, receipt):
    d = ctypes.CDLL(str(root))
    d.purifier_answer.argtypes = [ctypes.c_int]
    d.purifier_term.restype = None
    assert d.purifier_init() == 1
    values = [d.purifier_answer(i) for i in (0, 1)]
    assert values == [value, value + 1], values
    class Info(ctypes.Structure):
        _fields_ = [('fname', ctypes.c_char_p), ('base', ctypes.c_void_p),
                    ('symbol', ctypes.c_char_p), ('address', ctypes.c_void_p)]
    host = ctypes.CDLL(None)
    origins = []
    for marker, package in [('purifier_local_marker', 'purifier-local-answer'),
                            ('purifier_external_marker', 'purifier-external-answer')]:
        f = getattr(d, marker)
        f.restype = ctypes.c_int
        assert f() == value
        info = Info()
        assert host.dladdr(ctypes.cast(f, ctypes.c_void_p), ctypes.byref(info))
        actual = Path(info.fname.decode()).resolve()
        expected = [Path(r['path']) for r in receipt['runtimeOrigins'] if package in Path(r['path']).name]
        assert len(expected) == 1, expected
        origins.append({'symbol': marker, 'actual': str(actual), 'expected': str(expected[0]),
                        'matches': actual == expected[0], 'sha256': hashlib.sha256(actual.read_bytes()).hexdigest()})
    d.purifier_term()
    print(json.dumps({'values': values, 'origins': origins}))


if sys.argv[1] == '--probe':
    probe(Path(sys.argv[2]), int(sys.argv[3]), json.loads(Path(sys.argv[4]).read_text()))
    sys.exit(0)

prefix, competitor, out = map(Path, sys.argv[1:4])
ldd = sys.argv[4]
receipt_path = prefix / 'native-products.json'
receipt = json.loads(receipt_path.read_text())
other = json.loads((competitor / 'native-products.json').read_text())
root = Path(receipt['selectedRoot'])
rows = []


def run(path, value):
    p = subprocess.run([sys.executable, __file__, '--probe', str(path), str(value), str(receipt_path)],
                       text=True, capture_output=True, timeout=25)
    return p


positive = run(root, 42)
assert positive.returncode == 0 and not positive.stderr, positive
data = json.loads(positive.stdout)
assert all(r['matches'] for r in data['origins']), data
rows.append({'case': 'transitive-local-and-externalPaths', 'receipt': data})
ordinary99 = run(Path(other['selectedRoot']), 99)
assert ordinary99.returncode == 0 and not ordinary99.stderr, ordinary99
rows.append({'case': 'genuine-native-competitor99-positive', 'receipt': json.loads(ordinary99.stdout)})

controls = out / 'controls'
controls.mkdir()
local = next(Path(r['path']) for r in receipt['runtimeOrigins'] if 'libHSpurifier-local-answer' in Path(r['path']).name)
foreign = next(Path(r['path']) for r in other['runtimeOrigins'] if 'libHSpurifier-local-answer' in Path(r['path']).name)
assert hashlib.sha256(local.read_bytes()).digest() != hashlib.sha256(foreign.read_bytes()).digest()
for mode, target in [('missing', controls / local.name), ('replaced', foreign)]:
    path = controls / (mode + '.so')
    shutil.copyfile(root, path)
    path.chmod(0o755)
    if mode == 'replaced':
        for old in receipt['runtimeOrigins']:
            old_path = Path(old['path'])
            if 'libHSpurifier-' in old_path.name:
                candidates = [Path(r['path']) for r in other['runtimeOrigins'] if Path(r['path']).name == old_path.name]
                assert len(candidates) == 1, candidates
                subprocess.run(['patchelf', '--replace-needed', str(old_path), str(candidates[0]), str(path)], check=True)
    else:
        subprocess.run(['patchelf', '--replace-needed', str(local), str(target), str(path)], check=True)
    result = run(path, 99 if mode == 'replaced' else 42)
    if mode == 'missing':
        assert result.returncode != 0 and str(target) in result.stderr and 'cannot open shared object file' in result.stderr, result
        rows.append({'case': 'missing-local-loader-rejection', 'stderr': result.stderr})
    else:
        assert result.returncode == 0 and not result.stderr, result
        data = json.loads(result.stdout)
        assert any(not r['matches'] for r in data['origins']), data
        rows.append({'case': 'genuine99-competing-local-origin-rejected', 'rejected': True, 'receipt': data})

missing_store = controls / 'missing-store.so'
shutil.copyfile(root, missing_store)
missing_store.chmod(0o755)
needed = subprocess.check_output(['patchelf', '--print-needed', str(missing_store)], text=True).splitlines()
splitmix = [n for n in needed if 'libHSsplitmix' in n]
assert len(splitmix) == 1, needed
missing = controls / 'absent-store' / Path(splitmix[0]).name
subprocess.run(['patchelf', '--replace-needed', splitmix[0], str(missing), str(missing_store)], check=True)
result = run(missing_store, 42)
assert result.returncode != 0 and str(missing) in result.stderr and 'cannot open shared object file' in result.stderr, result
rows.append({'case': 'missing-locked-store-loader-rejection', 'stderr': result.stderr})

static = Path('static-control')
static.mkdir()
(static / 'static-control.cabal').write_text('cabal-version: 3.0\nname: static-control\nversion: 0.1.0\nbuild-type: Simple\nlibrary\n  exposed-modules: Static\n  build-depends: base\n  default-language: Haskell2010\n')
(static / 'Static.hs').write_text('module Static where\nanswer :: Int\nanswer = 42\n')
(static / 'cabal.project').write_text('packages: .\nactive-repositories: :none\n')
config = (Path.cwd() / 'static-cabal').resolve()
config.mkdir()
(config / 'config').write_text('active-repositories: :none\n')
subprocess.run(['cabal', 'build', 'all', '--offline', '--disable-shared'], cwd=static,
               env=dict(os.environ, CABAL_DIR=str(config)), check=True)
archives = list(static.rglob('libHS*.a'))
assert len(archives) == 1, archives
result = run(archives[0].resolve(), 42)
assert result.returncode != 0 and 'invalid ELF header' in result.stderr, result
rows.append({'case': 'genuine-Cabal-static-archive-loader-rejection', 'stderr': result.stderr})

(out / 'runtime-controls.json').write_text(json.dumps(rows, indent=2) + '\n')
print(json.dumps({'cases': [r['case'] for r in rows]}))
