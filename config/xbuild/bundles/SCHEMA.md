# The bundle description — what gets deployed, and where per-machine choices live

A **bundle** is the set of artifacts you copy to a target, plus the metadata needed
to deploy them. Like targets and components, it is a `KEY=value` file.

Bundles are where **per-machine composition decisions belong**. A component says
how to build itself; a target says what machine to build for; a bundle says *which
artifacts that machine actually needs*.

That last question is genuinely per-machine and there is no way to derive it: a
board with an FPGA needs the FPGA transport library, a plain server does not, and
the same server acting as a coprocessor needs different libraries than when acting
as a controller. Giving it its own file is what keeps that decision out of the
components (which would otherwise need target conditionals) and out of the target
description (which describes hardware, not deployment intent).

## Fields

| key | meaning |
|---|---|
| `BUNDLE_NAME` | **required.** Must match the filename. |
| `BUNDLE_DESC` | Free text. |
| `BUNDLE_COMPONENTS` | Component names to include. A missing one is an error. |
| `BUNDLE_OPTIONAL_COMPONENTS` | Included if built; silently omitted if not. For hardware-dependent pieces. |
| `BUNDLE_SYSROOT_LIBS` | Libraries to copy **out of the sysroot** into the bundle, e.g. `libstdc++.so.6`. See below. |
| `BUNDLE_EXTRA_FILES` | Extra files to include (scripts, configs), as `source:destname` pairs. |
| `BUNDLE_STRIP` | `yes` to strip symbols. Default `no`. |
| `BUNDLE_README` | Path to a file included as the bundle's README. |

## `BUNDLE_SYSROOT_LIBS` — shipping runtime libraries

If the target's `libstdc++` is older than what your code needs, you have three
options, and this field is usually the best of them:

1. **Ship the newer `libstdc++.so.6` in the bundle** — this field, plus the default
   rpath (`$ORIGIN` on an ELF target), which is what makes the loader find it beside
   the binaries. One extra file, no ABI games, and it is the same library you built
   against.
2. `COMPONENT_STATIC_CXX=yes` — safe only for leaf artifacts. See
   `components/SCHEMA.md` for why two static C++ runtimes in one process is a
   problem you do not want to debug.
3. Build against an older sysroot — correct, but often impractical.

The copy is taken from **the sysroot**, not the build host, so you ship the library
you actually linked against. Copying the host's would reintroduce exactly the
mismatch you were trying to fix. A name that is not there is reported —
`WARNING   <lib> requested by BUNDLE_SYSROOT_LIBS but not found in the sysroot` —
rather than quietly omitted.

Name the libraries as the target's loader knows them: `libstdc++.so.6` or
`libc++.so.1` on an ELF target, `libc++.1.dylib` on Mach-O. A macOS SDK sysroot has
no shared library for this field to copy, and that is not an oversight: the SDK
ships text stubs only (`usr/lib/libc++.1.tbd`), the library itself lives in the dyld
shared cache with no file on disk, and every Mac already has it. Needing to ship a
C++ runtime at all is a property of old ELF targets.

## Why the deploy script is generated, not written

`make bundle TARGET=… BUNDLE=…` produces a `deploy.sh` inside the bundle. It is
generated because it needs facts from three different places: the target's
`TARGET_DEPLOY_DIR`, the bundle's file list, and the run-time search path actually
baked into what was built — `$ORIGIN` for an ELF target, `@loader_path` for a
Mach-O one. That last one arrives already resolved, so a description that leaves
`TARGET_RPATH` blank still gets the right token in its deploy instructions rather
than the ELF spelling by assumption. Hand-written deploy instructions in a README
go stale the moment a component is added, and stale deploy instructions fail on
the target rather than on the build host.

## An honest note about what a bundle cannot fix

If a device library path is compiled into an artifact as an absolute build-host
path, no amount of bundling helps: the process will `dlopen` that absolute path
and ignore the copy sitting next to it. This is a real situation — one bundle in
the design being generalised deliberately omitted a device library for exactly
this reason, and documented that omission.

The bundler therefore *reports* what each artifact needs — it reads the load-time
dependencies (`NEEDED` entries via `readelf` for ELF, `otool -L` for Mach-O) and
names anything that is in neither the bundle nor the sysroot — but does not claim to
have satisfied it. A tool that silently implied a dependency was resolved when it was
not would be worse than one that tells you what it found.
