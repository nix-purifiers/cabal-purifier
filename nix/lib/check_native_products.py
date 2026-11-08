# SPDX-License-Identifier: MIT
"""Install and validate selected native Cabal foreign-library runtime closures."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import struct
import subprocess
import sys


def command(*args, **kwargs):
    return subprocess.check_output([str(a) for a in args], text=True, **kwargs).strip()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def elf(path, system):
    data = path.read_bytes()
    require(data[:6] == b'\x7fELF\x02\x01', f'not a little-endian ELF64 library: {path}')
    kind, machine = struct.unpack_from('<HH', data, 16)
    expected = {'x86_64-linux': 62, 'aarch64-linux': 183}.get(system)
    require(expected is not None and machine == expected and kind == 3,
            f'not a native shared object for {system}: {path}')
    phoff = struct.unpack_from('<Q', data, 32)[0]
    size, count = struct.unpack_from('<HH', data, 54)
    # GHC's genuine foreign-library output has PT_INTERP on this SDK.
    # Its zero entry point and absence of DF_1_PIE distinguish it from PIE.
    require(struct.unpack_from('<Q', data, 24)[0] == 0, f'executable entry point in foreign library: {path}')
    for i in range(count):
        header = phoff + i * size
        if struct.unpack_from('<I', data, header)[0] == 2:
            offset = struct.unpack_from('<Q', data, header + 8)[0]
            length = struct.unpack_from('<Q', data, header + 32)[0]
            for pos in range(offset, offset + length, 16):
                tag, value = struct.unpack_from('<QQ', data, pos)
                require(not (tag == 0x6FFFFFFB and value & 0x08000000),
                        f'PIE executable is not a foreign library: {path}')


def loader_map(path, ldd):
    env = {'PATH': os.environ['PATH'], 'LC_ALL': 'C'}
    text = command(ldd, path, env=env, stderr=subprocess.STDOUT)
    require('not found' not in text, f'missing runtime dependency of {path}: {text}')
    result = {}
    for line in text.splitlines():
        match = re.match(r'\s*(\S+) => (/\S+) \(', line)
        if match:
            result[match[1]] = Path(match[2]).resolve(strict=True)
        else:
            direct = re.match(r'\s*(/\S+) \(', line)
            if direct:
                path = Path(direct[1]).resolve(strict=True)
                result[path.name] = path
    return result


def main(out, spec_path, ldd):
    out = Path(out).resolve()
    spec = json.loads(Path(spec_path).read_text())
    plan = json.loads((out / 'plan.json').read_text())
    require(plan['compiler-id'] == 'ghc-' + spec['compiler']['version'], 'GHC identity differs from native plan')
    units = {u['id']: u for u in plan['install-plan']}
    key, product = next(iter(spec['products'].items()))
    package, kind, component = product['selector'].split(':')
    require(kind == 'flib', 'selected component is not a foreign library')
    roots = [u for u in units.values() if u['pkg-name'] == package and u.get('component-name') == 'flib:' + component]
    require(len(roots) == 1, 'selected foreign component missing or ambiguous in native plan')
    root_unit = roots[0]
    queue = [root_unit['id']]
    reachable = {}
    while queue:
        uid = queue.pop()
        require(uid in units, f'native plan dependency is absent: {uid}')
        if uid in reachable:
            continue
        reachable[uid] = units[uid]
        queue.extend(units[uid].get('depends', []))
    native_root = Path(root_unit['bin-file']).resolve(strict=True)
    require(native_root.is_relative_to(out / 'tree'), 'foreign artifact escaped persistent build tree')
    elf(native_root, spec['system'])
    exported = {line.split()[-1] for line in command('nm', '-D', '--defined-only', native_root).splitlines() if line.split()}
    require(set(product['exports']) <= exported, 'native foreign library lacks declared exports')
    native_install = out / 'native-install'
    installed_dirs = set()
    local_units = [u for u in reachable.values() if u.get('style') == 'local' and 'dist-dir' in u]
    for unit in local_units:
        dist = Path(unit['dist-dir']).resolve(strict=True)
        require(dist.is_relative_to(out / 'tree'), f'local component build directory is not retained: {dist}')
        if dist in installed_dirs:
            continue
        installed_dirs.add(dist)
        source = Path(unit['pkg-src']['path']).resolve(strict=True)
        descriptions = list(source.glob('*.cabal'))
        require(len(descriptions) == 1, f'ambiguous native package description for installation: {source}')
        build_types = re.findall(r'^build-type\s*:\s*([^\n]+)', descriptions[0].read_text(), re.I | re.M)
        require(len(build_types) == 1 and build_types[0].split('--')[0].strip().lower() == 'simple',
                'nativeProducts currently requires explicit build-type: Simple for installed local packages')
        subprocess.run(['cabal', 'act-as-setup', '--build-type=Simple', '--', 'copy',
                        '--builddir=' + str(dist), '--destdir=' + str(native_install)],
                       cwd=source, check=True)
    installed = {p.resolve(strict=True) for p in native_install.rglob('*.so*') if p.is_file()}
    require(all(p.is_relative_to(native_install) for p in installed), 'installed shared library escaped native installation')
    candidates = [p for p in installed if p.name == native_root.name and digest(p) == digest(native_root)]
    require(len(candidates) == 1, 'native-installed root is absent, ambiguous or differs from build bytes')
    installed_root = candidates[0]
    original_map = loader_map(installed_root, ldd)
    local_by_name = {}
    local_receipts = []
    for path in sorted(installed - {installed_root}):
        soname = command('patchelf', '--print-soname', path) or path.name
        require(soname not in local_by_name, 'ambiguous installed local SONAME: ' + soname)
        matches = {p.resolve() for u in local_units for p in Path(u['dist-dir']).rglob(path.name) if p.is_file()}
        matches = {p for p in matches if digest(p) == digest(path)}
        require(len(matches) == 1, f'installed local library lacks unique identical native artifact: {path}')
        built = matches.pop()
        local_by_name[soname] = path
        local_receipts.append({'soname': soname, 'nativeBuilt': str(built), 'nativeInstalled': str(path),
                               'nativeSha256': digest(built), 'installedSha256': digest(path)})
    # Preserve exact installed originals, and patch separate selected copies only.
    runtime_dir = out / 'runtime'
    runtime_dir.mkdir()
    selected_local = {}
    for soname, path in local_by_name.items():
        destination = runtime_dir / path.name
        require(not destination.exists(), 'ambiguous selected runtime filename: ' + path.name)
        shutil.copyfile(path, destination)
        destination.chmod(0o755)
        selected_local[soname] = destination
    library = out / 'lib' / key / ('lib' + key + '.so')
    library.parent.mkdir(parents=True)
    shutil.copyfile(installed_root, library)
    library.chmod(0o755)
    edits = []
    for path in [library, *selected_local.values()]:
        elf(path, spec['system'])
        for needed in command('patchelf', '--print-needed', path).splitlines():
            name = Path(needed).name
            if name in selected_local:
                target = selected_local[name]
                command('patchelf', '--replace-needed', needed, target, path)
                edits.append({'artifact': str(path), 'needed': needed, 'selected': str(target)})
    actual = loader_map(library, ldd)
    resolved = set(actual.values())
    for soname, expected in selected_local.items():
        require(expected.resolve() in resolved, f'installed local dependency was not loaded: {soname}')
    # Every originally resolved store/compiler dependency must remain identical;
    # local build dependencies must now resolve to the selected installed copy.
    built_local = {Path(r['nativeBuilt']) for r in local_receipts}
    for name, original in original_map.items():
        if original in built_local:
            require(name in selected_local and selected_local[name] in resolved,
                    f'local dependency origin differs from selected installation: {name}')
        else:
            require(original in resolved, f'compiler/store dependency origin changed: {name}')
    require(all(p.is_relative_to(out) or p.is_relative_to(Path(spec['storeDir'])) for p in resolved),
            'runtime dependency escaped immutable closure')
    compiler = Path(spec['compiler']['path']).resolve()
    store_units = [u['id'] for u in reachable.values() if u.get('type') != 'pre-existing' and u.get('style') != 'local']
    for path in resolved:
        if path.name.startswith('libHS'):
            if path.is_relative_to(runtime_dir) or path.is_relative_to(compiler):
                continue
            require(path.is_relative_to(out / 'cabal/store')
                    and any(('libHS' + uid + '-ghc' + spec['compiler']['version'] + '.so') == path.name
                            for uid in store_units),
                    f'Haskell runtime origin is outside the selected compiler/local/locked-store closure: {path}')
    require(not any(str(p).startswith(('/build/', '/tmp/')) for p in resolved), 'transient runtime dependency')
    include = out / 'include'
    include.mkdir()
    headers = list(Path(root_unit['dist-dir']).rglob('*_stub.h'))
    require(headers, 'native compiler produced no foreign-export stub header')
    header_rows = []
    for header in headers:
        destination = include / header.name
        require(not destination.exists(), 'ambiguous generated header name: ' + header.name)
        shutil.copyfile(header, destination)
        header_rows.append({'source': str(header), 'selected': str(destination), 'sha256': digest(destination)})
    sdk_dirs = shlex.split(command('ghc-pkg', '--global', 'field', 'rts', 'include-dirs', '--simple-output'))
    ghc_headers = {Path(d).resolve() for d in sdk_dirs if (Path(d) / 'HsFFI.h').is_file()}
    require(len(ghc_headers) == 1, 'ambiguous GHC HsFFI.h header directory')
    ghc_header = ghc_headers.pop()
    require(ghc_header.is_relative_to(compiler), 'HsFFI.h is outside the selected GHC compiler')
    shutil.copytree(ghc_header, include / 'ghc')
    (out / 'compiler-package-db.txt').write_text(command('ghc-pkg', 'dump', '--global') + '\n')
    receipt = {'product': product, 'compiler': spec['compiler'], 'nativeUnit': root_unit,
               'reachableNativeUnits': list(reachable.values()), 'nativeRoot': str(native_root),
               'nativeRootSha256': digest(native_root), 'installedRoot': str(installed_root),
               'installedRootSha256': digest(installed_root), 'selectedRoot': str(library),
               'selectedRootSha256': digest(library), 'localDependencies': local_receipts,
               'loaderEdits': edits, 'headers': header_rows, 'sdkHeaderDirectory': str(ghc_header),
               'nativeSDKIncludeDirectories': sdk_dirs,
               'sdkHsFFISha256': digest(include / 'ghc/HsFFI.h'),
               'runtimeOrigins': [{'name': n, 'path': str(p), 'sha256': digest(p)} for n, p in sorted(actual.items())],
               'lifetime': product['runtime'], 'system': spec['system']}
    (out / 'native-products.json').write_text(json.dumps(receipt, indent=2) + '\n')
    # Cabal's incremental caches embed file observation times. They are not
    # runtime inputs; keep the native artifacts/plan/package databases instead.
    caches = {Path.cwd() / 'dist-newstyle/cache'}
    caches.update(Path(u['dist-dir']) / 'cache' for u in local_units)
    for cache in caches:
        require(cache.is_relative_to(out / 'tree'), 'Cabal build cache escaped persistent project tree')
        if cache.is_dir():
            shutil.rmtree(cache)


if __name__ == '__main__':
    try:
        main(*sys.argv[1:])
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit('cabal-purifier: nativeProducts: ' + str(error))
