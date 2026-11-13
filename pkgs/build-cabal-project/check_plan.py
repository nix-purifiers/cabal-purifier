# SPDX-License-Identifier: MIT
"""Checks that a build resolved to the plan of the lock.

Usage: check_plan.py PLAN_JSON LOCK_UNITS_JSON

PLAN_JSON is the plan.json that Cabal wrote for the build, and
LOCK_UNITS_JSON is the lock's list of units for the build's system. Each
package of the plan (name, version and flags) must be one the lock holds,
and the other way round. A package the compiler provides must be one the
lock left to the compiler. Whether Cabal treats a package as local is not
compared: a package URL is a global package in the lock run, and the
unpacked directory the build lists in its place is a local one.
"""

import json
import sys


def plan_units(plan):
    units = {}
    for unit in plan["install-plan"]:
        name, version = unit["pkg-name"], unit["pkg-version"]
        installed = unit["type"] == "pre-existing"
        flags = tuple(sorted((unit.get("flags") or {}).items()))
        units[(name, version)] = (installed, flags)
    return units


def lock_units(units):
    return {
        (u["name"], u["version"]): (u["installed"], tuple(sorted(u["flags"].items())))
        for u in units
    }


def describe(key, value):
    installed, flags = value
    kind = "provided by the compiler" if installed else "built"
    flag_text = " ".join(("+" if on else "-") + f for f, on in flags)
    return f"{key[0]}-{key[1]} ({kind}{', ' + flag_text if flag_text else ''})"


def main(plan_path, units_path):
    with open(plan_path) as f:
        built = plan_units(json.load(f))
    with open(units_path) as f:
        locked = lock_units(json.load(f))
    if built == locked:
        return 0
    print("cabal-purifier: the build resolved to a plan that differs from the lock.", file=sys.stderr)
    for key in sorted(set(built) | set(locked)):
        if built.get(key) != locked.get(key):
            if key in locked:
                print(f"  locked: {describe(key, locked[key])}", file=sys.stderr)
            if key in built:
                print(f"  built:  {describe(key, built[key])}", file=sys.stderr)
    print(
        "Run `cabal-purifier relock`, and check that the build uses the "
        "compiler the lock names.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
