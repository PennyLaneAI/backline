# Working in this tree — instructions for AI agents

> **Which job are you here to do?**
>
> * **Building a project's deliverables** — its own instructions name the target, the
>   components and the bundle. This file cannot: nothing in this directory knows which
>   machine you meant, which is the whole design. In this checkout, start at
>   [`../../AGENTS.md`](../../AGENTS.md) and [`../../INSTALL.md`](../../INSTALL.md).
>   First command either way: `make list-targets` — if your machine is listed, it is already
>   described and you skip the whole probe/sysroot setup.
> * **Changing the build system itself** — you are in the right place. Read on.

One file, at the top level, deliberately. The invariants below are *global* — they are
properties of how `targets/`, `mk/`, `tools/` and `sysroot/` relate to each other, not of
any one directory. Per-directory copies would be four places to update and four places to
forget, which is the exact defect this build system exists to remove.

Humans: this is also a fair summary of the rules. `docs/01-concepts.md` explains why they
exist.

---

## What this tree is

A cross-compilation build system where **machines are data**. Three kinds of `KEY=value`
description (`targets/`, `components/`, `bundles/`) are consumed by a generic engine
(`mk/`, `tools/`, `sysroot/`) that contains no machine-specific knowledge.

Two properties are load-bearing. Preserve both or the change is wrong:

1. **Adding hardware is one file in `targets/`.** No new recipe, no new cmake file, no edit
   under `mk/` or `tools/`. If a change makes adding a board require touching the engine,
   the change is the bug.
2. **A remote runtime failure is converted into a local build-time error.** Every check in
   the tree exists to turn a confusing failure on the device into a specific message on the
   build host. A change that removes a check, or makes one pass when it cannot actually
   verify, is a regression even if nothing fails.

---

## Verify, do not assert

This is the rule that matters most here. Build-system bugs do not look like build-system
bugs — they look like the user's code being broken. Confident prose about what a change does
is worth nothing next to a command that shows it.

**Before claiming any change works:**

```bash
make check              # every description parses; every reference resolves — seconds
make test               # the build system's own regression suite — about a minute
```

`make check` runs `make validate` and then cross-checks every bundle→component reference, so
it is the superset and the one to run. `make test` is a thin wrapper around
`tests/run-tests.sh`; either spelling works, and `make help` advertises the goal names.

Both must pass. Report the actual result, including failures and skips. Never describe a
test run you did not perform. Some groups are host-specific — the ELF ABI checks skip where
the host does not compile ELF, the Mach-O ones where it does — and a skip that names its
reason is the expected outcome there, not a failure to chase. `make doctor` reports the
`bash` and `make` in use among the host facts; that line is the first thing to read if a
description comes back truncated.

**When fixing a defect:** reproduce the wrong output *first*, paste it, then show the same
command producing the right output. A fix with no before/after is a guess.

**When adding behaviour:** add a test to `tests/run-tests.sh` in the existing style — the
`it "…"` string names *the failure the test prevents*, not the assertion it makes. A change
to `mk/`, `tools/` or `sysroot/` without a test is incomplete.

**Prefer a check to a claim.** If a statement can be settled by running something —
`make show-target`, `make sysroot-info`, `make show-component`, `readelf` — run it and quote
the output instead of reasoning about it in prose.

---

## Safety

**Never run without the user asking for that specific action:**

* `make probe SSH=…` — connects to a real machine over ssh and **writes
  `targets/<name>.conf`**, containing hostnames and usernames. Only probe a host the user
  named in this conversation.
* `make sysroot` with the `ssh-rsync`, `oci`, `tar url=` or `debootstrap` providers — these
  reach the network, and `debootstrap` needs root. Say what will happen and ask first.
* `make sysroot-clean`, `make clean-all` — destructive. `clean` and `clean-target` are safe.
* Anything that writes outside this tree, or outside `build/` within it.

**Never do at all:**

* Commit, push, or amend unless explicitly asked. If asked, branch first — never commit to
  `main` directly.
* Commit `build/`, `config.mk`, probe output, or `*.conf.bak.*`. Probe output contains
  infrastructure hostnames.
* Hand-roll `rm -rf` on a path built from variables. The one place that does it
  (`sysroot/providers/ssh-rsync`) guards every component with `${VAR:?}` and an
  is-it-a-symlink test; do not loosen those, and do not copy the pattern elsewhere.
* Make a `.conf` file executable, or add `$(...)`, `${...}` or backticks to a target
  description. Descriptions are inert data; `tools/conf2mk.sh` enforces this and the
  enforcement is a security boundary, not a style rule.
* Edit anything under `build/`. It is generated and `rm -rf build` must remain a complete
  reset.
* Send tree contents to an external service.

---

## The invariants, by area

| area | the rule | how it breaks |
|---|---|---|
| `targets/ components/ bundles/` | pure `KEY=value` data. No logic, no commands, no target name in a component | a description that can run code is a program, and a security problem |
| `tools/conf2mk.sh` | **the only** description parser. Two generated views: Make, and shell via `tools/load-conf.sh` | a second parser drifts — see item 8 in `IMPROVEMENTS.md` for a live example |
| `mk/derive.mk` | **the only** place data becomes compiler flags | two composers diverge, and the binary fails on the device, not here |
| `tools/gen-cmake-toolchain.sh` | generated from the same variables, never hand-maintained | this is what replaced a `KEEP IN SYNC` comment |
| `tools/arch-table.sh` | **the only** table of architecture facts. Fails *closed* on an unknown arch | a table that fails open verifies an x86-64 binary as fit for a loongarch64 board |
| `sysroot/providers/` | one executable per provider; the filename is the registration | normalisation, validation and provenance are applied by `get-sysroot.sh`, so providers must not reimplement them |
| `tools/detect-host.sh` | ask the tool where it is; never hardcode a distro path | `/usr/lib/llvm-18` is Debian-only and made the old tree silently Ubuntu-only |
| portable shell | the engine's scripts are `#!/usr/bin/env bash` and must run under bash 3.2 (macOS's `/bin/bash`) with a BSD userland. The one exception is `sysroot/probe/probe-target.sh`, which is `#!/bin/sh` because it runs on the TARGET, where busybox may be all there is | a bash-4 construct or a GNU-only tool flag fails **silently**: a negative substring length truncated every description while exiting 0, and a GNU-only `sed` group made `make check` verify nothing and print ok. `tests/run-tests.sh` has three scanners that fail if any of them is reintroduced |
| `mk/rules.mk` | one recipe per `COMPONENT_KIND`. Three kinds, three recipes | recipe count must stay O(kinds), never O(components × targets) |
| `mk/component.mk` | one sub-make process per component, for variable isolation | sharing a process leaks one component's flags into the next |
| native builds | a target whose sysroot is the host's own — `/`, or the SDK on macOS, discovered by the `native` provider. Same recipes, same verifier, same bundler | a second code path means two sets of bugs |

---

## Things not to do, learned the hard way

Each of these was a real defect in this tree or its ancestor. Do not reintroduce them.

* **Do not add a `sed`-based reader for a `.conf`.** Use `conf2mk.sh` or `load-conf.sh`.
  Ad-hoc readers miss trailing-comment stripping and quote handling, and the result is a
  value that is right for one consumer and silently wrong for another.
* **Do not add compiler flags outside `mk/derive.mk`.** If a flag must be conditional on
  something, the condition belongs in `derive.mk` keyed on a description field.
* **Do not name a board, distro, GCC version or vendor path anywhere in `mk/` or `tools/`.**
  It goes in a description or in `arch-table.sh`. `mk/derive.mk` does name `amd` and `nvidia`,
  which is compatible: it derives them from how `TARGET_GPU_ARCH` is spelled (`gfx<n>` or
  `sm_<n>`) and holds the flag spellings each vendor's compiler needs. No machine and no path
  is named, and adding an NVIDIA machine is still one file in `targets/`.
* **Do not make a check pass when it cannot actually verify.** Report "cannot check, here is
  why" — the tree treats a false PASS as worse than no check.
* **Do not silence an error into a skip** unless the skip is reported by name with a reason.
* **Do not truncate, sample, or cap output silently.** If something was omitted, say what
  and why.
* **Do not use a bash-4 construct or a GNU-only tool flag.** Named, because each one was
  found here: an associative-array declaration (`declare -A`), a negative substring length
  (`${v:1:-1}`), in-place `sed -i`, a relative `touch -d`, `paste -sd` without a trailing
  `-`, GNU BRE optional/alternation escapes (`\?`, `\|`), and coreutils `timeout`. Spell the
  length arithmetically, use the string-set idiom, and use the suite's portable stand-ins.
* **Do not assume the artifact is ELF.** `readelf`, an interpreter, `$ORIGIN` and a glibc
  symbol version are all one format's answers. Branch on `TARGET_BINFMT` and say `n/a`, with
  the reason, for the checks that do not apply.
* **Do not "fix" `$$ORIGIN` to `$ORIGIN` in a description.** The doubling is required; a
  single `$` becomes the literal string `RIGIN` in the binary's RPATH. On Mach-O the token
  is `@loader_path` instead, and the linker accepts the ELF spelling silently and records it
  for a loader that will never expand it — so the safe answer is to leave `TARGET_RPATH`
  blank and let `mk/derive.mk` pick the one the format needs.

---

## Style

Match the surrounding code. Two specifics:

* **Comments say *why*, and quote the real error.** The verbatim compiler/loader output in
  these files is the most valuable content in the tree. When you fix something, record the
  message it produced.
* **Do not name a specific board in `mk/`, `tools/` or `docs/`.** Machines are named in
  `targets/*.conf` and nowhere else — that is the tree's central claim, and prose that keeps
  citing one device undermines it even when the code is clean. If an example needs a concrete
  machine, reach for a described `example-*` target, not hardware someone happens to own.
* Keep new prose proportionate. This tree is already heavily commented; adding more
  narrative around an existing explanation makes it harder to find, not easier.

---

## Commands

```bash
make help                          # every goal
make doctor                        # can this host cross-compile, and what is missing
make check                         # validate descriptions + cross-check references
tests/run-tests.sh [-v]            # the regression suite

make show-target    TARGET=t       # fully resolved settings and the exact flags
make show-component TARGET=t COMPONENT=c
make sysroot-info   TARGET=t       # what the sysroot actually contains

make sysroot TARGET=t              # network/privilege — ask first
make build   TARGET=t [COMPONENT=c]
make verify  TARGET=t [STRICT=1]
make bundle  TARGET=t BUNDLE=b
```

`make build TARGET=<t>` with no `COMPONENT=` currently fails on a clean checkout: the
shipped example components require the external `CATALYST` tree. That is a known defect
(item 9 in `IMPROVEMENTS.md`), not something you broke. Build `COMPONENT=hello-world` to
exercise the pipeline.

---

## Before you say you are done

1. `make check` passes.
2. `tests/run-tests.sh` passes — quote the counts.
3. New or changed behaviour in `mk/`, `tools/` or `sysroot/` has a test naming the failure
   it prevents.
4. Nothing generated was committed, and nothing outside `build/` was written that the user
   did not ask for.
5. Anything you could not finish is stated plainly, with the reason.
