# SPDX-License-Identifier: MIT
"""Writes an offline copy of a Cabal project's configuration.

Cabal reads a project from `cabal.project` and, beside it,
`cabal.project.freeze` and `cabal.project.local`. The copy that this
module writes is what the sandboxed build and `cabal-purifier cabal` run
Cabal with, through `--project-dir` (the project's own directory) and
`--project-file` (the copy). The copy differs from the project's files in
these ways:

- `source-repository-package` sections are left out. The packages they
  provide are in the purifier's local repository, as tarballs packed from
  the locked checkouts.
- `repository` sections and the `active-repositories` and `index-state`
  fields are left out. The purifier's Cabal configuration names its local
  repository as the only active one.
- A URL in `packages`, `optional-packages` or `extra-packages` becomes the
  directory that holds the locked, unpacked tarball.
- An `import` of a local file is replaced by that file's rewritten text, so
  the copy does not depend on the directory it is written to.
- The constraints of the lock go in a `constraints` field at the end of
  the main file, so Cabal resolves to the locked plan.

The module runs as a script in the Nix build and is imported by the
`cabal-purifier` command.
"""

import argparse
import json
import re
import sys
from pathlib import Path

PROJECT_FILE = "cabal.project"
COMPANIONS = ("freeze", "local")
DROPPED_SECTIONS = re.compile(r"(source-repository-package|repository)(\s|$)", re.IGNORECASE)
DROPPED_FIELDS = re.compile(r"(active-repositories|index-state)\s*:", re.IGNORECASE)
PACKAGE_FIELDS = re.compile(r"(packages|optional-packages|extra-packages)\s*:", re.IGNORECASE)
IMPORT_FIELD = re.compile(r"import\s*:\s*(.*)$", re.IGNORECASE)


class ProjectError(Exception):
    """A project configuration that the offline copy cannot express."""


def blocks(text):
    """Splits project text into top-level blocks.

    A block starts at a line that begins in column 0 and is neither blank
    nor a comment. It takes every following line that is blank, a comment,
    or indented. Text before the first block is a block of its own.
    """
    current = []
    for line in text.splitlines(keepends=True):
        starts = line[:1] not in ("", " ", "\t", "\n", "\r") and not line.startswith("--")
        if starts and current:
            yield current
            current = []
        current.append(line)
    if current:
        yield current


def rewrite_packages(lines, remote):
    """Replaces each locked URL in a packages field with its directory."""
    out = []
    for line in lines:
        for url, directory in remote.items():
            line = line.replace(url, directory)
        out.append(line)
    return out


def rewrite(path, remote, seen=()):
    """The offline text of one project file, with its imports inlined."""
    path = Path(path).resolve()
    if path in seen:
        raise ProjectError(f"{path} imports itself")
    text = path.read_text()
    out = []
    for block in blocks(text):
        header = block[0]
        if DROPPED_SECTIONS.match(header) or DROPPED_FIELDS.match(header):
            continue
        if PACKAGE_FIELDS.match(header):
            out.extend(rewrite_packages(block, remote))
            continue
        imported = IMPORT_FIELD.match(header)
        if imported:
            target = imported.group(1).strip()
            if re.match(r"[a-z]+://", target):
                raise ProjectError(
                    f"{path} imports {target}; an import by URL is fetched while "
                    "Cabal reads the project, so the offline copy cannot hold it. "
                    "Copy the file into the project and import it by path."
                )
            out.append(f"-- imported from {target}\n")
            out.append(rewrite(path.parent / target, remote, seen + (path,)))
            out.append("\n")
            continue
        out.extend(block)
    return "".join(out)


def write(project_dir, output_dir, remote=None, constraints=()):
    """Writes the offline copy of the project at project_dir to output_dir.

    `remote` maps each locked package URL to its unpacked directory.
    `constraints` are Cabal constraint strings, one per line of the
    generated `constraints` field. Returns the path of the main file.
    """
    project_dir = Path(project_dir)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    remote = remote or {}
    main = project_dir / PROJECT_FILE
    if main.exists():
        text = rewrite(main, remote)
    else:
        # Cabal's implicit project when there is no cabal.project.
        text = "packages: ./*.cabal\n"
    if constraints:
        text += "\n-- The plan of the cabal-purifier lock.\nconstraints:\n"
        text += ",\n".join(f"  {c}" for c in constraints) + "\n"
    (output_dir / PROJECT_FILE).write_text(text)
    for companion in COMPANIONS:
        source = project_dir / f"{PROJECT_FILE}.{companion}"
        target = output_dir / f"{PROJECT_FILE}.{companion}"
        if source.exists():
            target.write_text(rewrite(source, remote))
        elif target.exists():
            target.unlink()
    return output_dir / PROJECT_FILE


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument(
        "--remote", help="a JSON file mapping each locked package URL to its directory"
    )
    parser.add_argument("--constraints", help="a file of Cabal constraints, one per line")
    args = parser.parse_args(argv)
    remote = json.loads(Path(args.remote).read_text()) if args.remote else {}
    constraints = (
        [c for c in Path(args.constraints).read_text().splitlines() if c.strip()]
        if args.constraints
        else []
    )
    try:
        write(args.project_dir, args.output_dir, remote, constraints)
    except ProjectError as error:
        print(f"cabal-purifier: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
