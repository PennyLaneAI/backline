# Improvements — done, and still open

Findings about this build system's own behaviour, with the evidence attached. Each entry says
what goes wrong, the measurement or error output that demonstrates it, what to change, and what
the change risks — so nobody has to re-derive the reasoning later.

Nothing here is a bug report against a component you are building.

Open items are ordered by (size of win ÷ risk), highest first.

---

## Done

Kept here rather than deleted: the evidence is the reason the change looks the way it does,
and the next person to touch these files should be able to find it.

| item | what changed | verified by |
|---|---|---|
| 1. `/lib` copied twice | `sysroot/providers/ssh-rsync` reproduces a symlinked path instead of following it. A stock Ubuntu 24.04 aarch64 target went from **297M to 162M**; a re-fetch also removes the duplicate an earlier fetch left behind. | live fetch, plus a suite test that the copy loop still detects symlinks |
| 4. `COMPONENT_LIBS` unchecked | new `sysroot-inspect.sh haslib` mode, called by both direct recipes. Distinguishes "no such library" from "runtime library present, `-dev` package missing", and accepts `.a`-only libraries so glibc ≥ 2.34's absorbed `libpthread`/`libdl`/`librt` still pass. | 4 suite tests |
| 5. bare `Error 127` | both direct recipes check the compiler first, naming the component and whether the name came from `COMPONENT_CXX_OVERRIDE` or `TOOLCHAIN_KIND`/`TOOLCHAIN_ROOT`. | suite test |
| 6. probe wrote an unreachable `host=` | `tools/probe-over-ssh.sh` records the address that actually reached the machine, keeping the machine's own hostname as a comment. `make sysroot` now works straight after `make probe` with no override. | live probe of the Docker pseudo-remote |
| 7. LLVM error didn't name `make catalyst-llvm` | `examples/executor/CMakeLists.txt` names the command, for both the cross and native cases. | — |

---

## Still open

## 20. Externalising the docs: measured verbosity, a numeric standard, and a lint

**Impact:** the largest remaining task before publication. A reader currently meets the
history of the implementation before they meet the tool. Items 13 and 18 name two symptoms
(project-specific knowledge in the engine; one rationale told eight times); this item supplies
the measurements, the threshold to hold the line at, and the check that keeps it held.

### Measured, not asserted

Comment text as a share of all words, and the longest single run of comment lines:

| file | comment words | code words | comments | longest block |
|---|---|---|---|---|
| `tools/gen-cmake-toolchain.sh` | 1249 | 264 | **82%** | 32 lines |
| `tools/load-conf.sh` | 264 | 74 | **78%** | 30 |
| `tools/arch-table.sh` | 352 | 142 | 71% | 25 |
| `tools/detect-host.sh` | 776 | 406 | 65% | 29 |
| `sysroot/providers/ssh-rsync` | 1067 | 571 | 65% | 29 |
| `tools/conf2mk.sh` | 1504 | 908 | 62% | **57** |
| `tools/sysroot-inspect.sh` | 2060 | 1359 | 60% | 45 |
| `examples/executor/CMakeLists.txt` | 768 | 514 | 59% | 29 |
| `tools/build-catalyst-llvm.sh` | 776 | 527 | 59% | 35 |
| `Makefile` | 1324 | 2117 | 38% | 30 |

Prose surface: **19,883 words** across 14 markdown files — `IMPROVEMENTS.md` 3241,
`docs/06` 2603, `docs/05` 2242, `AGENTS.md` 1424, `targets/SCHEMA.md` 1318, `README.md` 1273,
`components/SCHEMA.md` 1243, `docs/01` 1187, `docs/03` 1097, `TLDR.md` 1069, the rest smaller.

### Must not ship at all

* `AGENTS.md` — agent instructions.
* `IMPROVEMENTS.md` — this file; an internal work log.
* `docs/06-porting-from-the-vpk-only-design.md` — 2603 words about a codebase no external
  reader has seen, naming internal artefacts (`CROSS_VPK120_FLAGS`, `hwhs-controller-session`,
  `vpk-bundle.sh`). Note this conflicts with item 18, which proposes `docs/06` as the canonical
  home for the rationale: pick one. Recommend keeping the *argument* in `docs/01` and dropping
  the predecessor comparison entirely, since it only means something internally.
* `tools/gen-cmake-toolchain.sh`'s header quotes the old tree's `KEEP IN SYNC` comment
  verbatim over ~20 lines. The lesson survives in one sentence; the quotation does not.

### The standard

* A comment says what the code does and what breaks if you change it, in **one to three
  lines**. No block over 10 lines outside a file header. **No file over 35% comment words.**
* File headers state purpose, usage, contract — not rationale. Reasons needing more than three
  lines move to `docs/` and the comment cites the anchor, per item 18's `WHY:` convention.
* `Regression:` / `Observed:` / `Measured on…` / `reported from the field` framing is allowed
  **only** in `tests/`, where a failure story is the point (30 occurrences there today, which
  is fine). Elsewhere it is history and belongs in version control.
* No reference to any predecessor design, by name or anecdote.
* Second person for the reader, present tense for behaviour, no first person.
* Keep verbatim compiler and loader output — per item 18 and the "Not to be changed" list
  below, those blocks are the highest-value content in the tree and are not what makes it
  verbose. The distinction this item draws: keep the *quoted output*, drop the *narrative
  wrapper* around it. "fatal error: 'cstdio' file not found" earns its place; three sentences
  recounting when it was first seen do not.

### Work list

| # | change | scale |
|---|---|---|
| a | trim the ten files above to ≤35%, relocating each surviving reason into `docs/` as you go | ~4000 comment words |
| b | exclude `AGENTS.md` and `IMPROVEMENTS.md` from the published tree | 2 files |
| c | drop the predecessor comparisons: `docs/06` and the `gen-cmake-toolchain.sh` header | ~2900 words |
| d | rewrite the three `SCHEMA.md` files as reference tables — field, meaning, default, one-line consequence | 3145 → ~1200 words |
| e | add the lint (below) | new test |

Deferred to their own items, not restated here: deduplicating the shared rationale (18),
separating Catalyst-specific material from the engine (13), CI and `shellcheck` (19).

### The lint, and why it comes first

A mechanical check in `tests/run-tests.sh`, failing when a shipped file exceeds 35% comment
words, when a banned phrase appears outside `tests/`, or when `AGENTS.md` / `IMPROVEMENTS.md`
are present in the tree. Do this **before** (a): without it the ratio creeps straight back and
every judgement above is re-litigated by hand.

**Risk — the real one.** These comments carry knowledge that exists nowhere else; several are
the only record of why a flag is shaped as it is. Trimming without relocating converts a
verbosity problem into a knowledge-loss problem. Work file by file, moving each reason into a
doc section first, and never as a bulk sweep.

**Not in scope: private data.** Already verified clean — no real hostnames, usernames, IP
addresses, local absolute paths or container identifiers anywhere outside `build/`. The only IP
present is the documentation example `192.168.1.50` in `docs/02-adding-a-target.md`, which is
RFC1918 and intended.

---

## 21. Flag composition: one taxonomy, two spellings, three leaks

Found by a cleanup review of the `TARGET_STD_FLAG` change; recorded rather than fixed because
each part changes behaviour, and item 10 ("one flag composer") is the right home.

**Evidence, all measured with `make -f mk/component.mk … component-info` on `test-native-gcc`:**

* A native component **still receives** `SYSROOT_CXX_FLAGS` — `-isystem …/sysroots/<t>/usr/include/c++/13`,
  `-B…/usr/lib/gcc/…` and `-L…/sysroots/…` on the link line. Those are *more* machine-specific
  than the `--sysroot=` that is withheld, so "native gets no machine flags" already leaks.
* The native policy is spelled **twice**: `ifeq` for the compile path, and an inline
  `$(if $(filter yes,$(COMPONENT_REQUIRES_NATIVE)),,$(TARGET_LINK_FLAGS))` for the link path. Only
  the compile spelling keeps the standard, so a native component links with the default linker
  while every sibling uses `TARGET_LINKER` — confirmed: `-fuse-ld=` absent natively, present
  otherwise. Linker choice is toolchain policy, not a machine property.
* `-stdlib=libc++` and `TARGET_CXXFLAGS` are dropped for native components too. On a
  `TARGET_STDLIB=libc++` target that gives the native component the compiler default while its
  siblings get libc++ — the two-C++-runtimes-in-one-process hazard `mk/rules.mk` warns about.

**Suggested change.** Compose named groups in `mk/derive.mk` — machine (triple, cpu, sysroot,
linker), language (`-std`, `-stdlib`), user (`TARGET_CXXFLAGS`) — with `TARGET_CXX_FLAGS` as their
concatenation, and have `mk/rules.mk` name which groups a native component omits, once, for both
the compile and link paths. `_INHERITED_CXX_FLAGS` (renamed from `_MACHINE_FLAGS` in this pass,
because it no longer holds only machine flags) then disappears into that selection.

**Then make it data.** The current rule hardcodes "a native component gets the standard", resting
on the claim that every vendor compiler accepts `-std=gnu++NN`. `nvcc` is the counterexample: it
takes `-std=c++20` and rejects `-std=gnu++20`. A pure-C native component wants no `-std` at all.
There is no `COMPONENT_CXX_STANDARD` and no way to say "none" — `components/SCHEMA.md` does not
mention `-std` — so the only escape is appending a later `-std=` via `COMPONENT_CXXFLAGS` and
relying on last-wins, which is undocumented. A `COMPONENT_FLAG_GROUPS=lang user` field over the
taxonomy above covers hipcc, nvcc and C-only components without a second special case.

**Risk:** each bullet is a behaviour change for existing components, which is why none was taken
here. Do it with item 10, in one pass, so the public behaviour changes once.

---

## 22. Repeated process spawns in the per-component pre-flight checks

Found by the same review. Measured, not estimated.

**One `sysroot-inspect.sh haslib` invocation costs 22 process spawns** — its own bash, `dirname`,
`detect-host.sh` plus that script's `tr`/`grep`/`paste`, and `find_gccver`'s subshell with
`ls|grep|sort|tail`. `_CHECK_LIBS` in `mk/rules.mk` spawns one **per library**, so
`example-transport-session` (`ibverbs pthread dl rt`) pays 4 × 22 = **88 processes**, timed at
38 ms against 9 ms for a single call. Every repeat recomputes `find_libdir`, `find_gccver` and
`TRIPLE_ALT`, none of which depend on the library name. `COMPONENT_LIBS` lengths across
`components/*.conf`: 4, 4, 3, 2, 2, 2.

*Fix:* let `haslib` take the whole list and resolve the sysroot facts once. It would also report
every unlinkable library instead of dying on the first. Snag: `haslib` currently reads `GCC_PIN`
from `$5`, which collides with a variadic name list, so the pin needs another home.

**`TRIPLE_ALT` is computed unconditionally at startup**, above the `case $MODE` dispatch and above
every `sysroot_exists || exit 0` — so every invocation of every mode pays one `detect-host.sh`
spawn, including modes that never use a triple. Measured: `gccver` costs 22 execve for what is a
glob plus `ls|grep|sort|tail`; an absent-sysroot `cxxflags` costs **18 execve** for a call
documented as a silent no-op. A **no-op** `make build TARGET=example-native` (nothing to rebuild)
makes 22 `sysroot-inspect.sh` invocations and therefore 22 `detect-host.sh` spawns, ~150 processes
for zero build work.

*Fix:* make it a lazily-initialised, memoised `triple_alt()`. `triple_variants()` is already the
accessor everywhere except `libdir_candidates` and `report`, so three call sites change. Also
`$(dirname "$0")` → `${0%/*}` drops one more spawn.

**Exporting recursive `SYSROOT_CXX_FLAGS`/`SYSROOT_LINK_FLAGS`** from `mk/exports.mk` re-runs the
probe once per recipe: `mk/derive.mk` deliberately makes them `=` (deferred), and GNU Make expands
an exported recursive variable each time it builds a child environment. Verified on Make 4.3 with a
minimal Makefile: recursive + `export` + 3 recipe targets = 3 expansions; `:=` = 1. In this repo a
`-B` single-component build ran `cxxflags` 3× and `ldflags` 3× where 1 each is needed.

*Fix:* memoise so laziness and single-expansion coexist —
`SYSROOT_CXX_FLAGS = $(eval SYSROOT_CXX_FLAGS := $(shell …))$(SYSROOT_CXX_FLAGS)` — verified to
give 1 expansion across 3 recipes with the value still reaching each child environment.

**Related, pre-existing:** `sysroot-inspect.sh probe` runs once per component from `mk/rules.mk`,
even though the top-level `build` recipe already probed the same unchanging sysroot — and the
Makefile explicitly reasons that `linkability` was placed once at the top *because* putting it in
`rules.mk` "would repeat it for every component in the run". The same argument applies to `probe`.

**Risk:** low for the memoisation and the lazy triple; moderate for the `haslib` signature change,
which is a public-ish interface (`tests/run-tests.sh` calls it directly in four tests).

---

## 23. `catalyst-executor`: the split is done, two couplings remain

**Done.** The engine-grade half now lives in `cmake/CrossbuildFindLLVM.cmake`, a reusable module
("given a target and a version window, pick an LLVM that can be linked, and explain every
rejection"). The project moved out of `examples/` to `recipes/catalyst-executor/`, which holds only
Catalyst specifics: `CATALYST_SRC`, the 20-22 window, and the `make catalyst-llvm` guidance.
`components/example-executor.conf` points at the new path.

The module encodes the policy that the pinned checkout is authoritative: a project is written
against the LLVM its own checkout pins, so that is searched by default and any other installation
is opt-in (`-DCATALYST_EXECUTOR_ALLOW_SYSTEM_LLVM=ON`, or an explicit `-DLLVM_DIR`). Architecture
comparison goes through `tools/arch-table.sh deb-arch`, so the duplicated aarch64/arm64 alias
table is gone and `aarch64` asked for against `arm64` reported is no longer a mismatch. The
generated toolchain now emits `CROSSBUILD_TARGET_ARCH` (canonical) and `CROSSBUILD_CMAKE_DIR`, so
a component never has to guess either. Four suite tests drive the module with fake
`LLVMConfig.cmake` fixtures, needing no LLVM install.

**Still open, both small:**

* The component is still named `example-executor` while its project lives in `recipes/`. Renaming
  it to `catalyst-executor` touches three bundles, the tests and the docs, so it belongs with
  item 13's namespace split rather than being done piecemeal.
* `tools/build-catalyst-llvm.sh` still chooses its output directory name (`build-<arch>`) because
  the recipe globs for `*build*`. That contract is now stated in both files but is still a glob
  rather than an interface — the tool could write a marker file, or the recipe could be told the
  path directly.

---

## 2. Static archives are copied but never linked

**Impact:** ~34M per sysroot in the aarch64 example. (It was double that before item 1
removed the duplicated tree.)

**Evidence.**

```
under usr/lib:   *.so*  163.3M (562 files)
                 *.a     33.7M  (54 files)
```

Every component in this tree links shared. `COMPONENT_STATIC_CXX=yes` uses
`-static-libstdc++`, which needs `libstdc++.a` — so the set is not empty, but it is small and
knowable.

**Suggested change.** Exclude `*.a` by default in the providers, with a target-level opt-out
(`SYSROOT_KEEP_STATIC=yes`) for anyone who links statically. Print what was skipped, in the
spirit of the existing "no silent caps" rule — a sysroot that quietly lacks archives someone
needs is exactly the sort of surprise this tree exists to prevent.

**Risk:** medium. `libc_nonshared.a` is referenced by the `libc.so` *linker script* on glibc
and must be kept, as must `libstdc++.a` if any component sets `COMPONENT_STATIC_CXX`. An
exclude list that is too broad breaks linking in a way that reads as a missing symbol.

---

## 3. Optional interface-stub sysroots (`llvm-ifs`)

**Impact:** the library tree shrinks by ~34x. Measured on the aarch64 example:

```
libc.so.6         1.7M  ->  104K
libstdc++.so.6    2.6M  ->  444K
libm.so.6         580K  ->   40K
multiarch libdir  173M  ->  5.1M      (158 of 160 libraries stubbed successfully)
```

A binary built against a fully stubbed sysroot compiles, links, and **runs correctly on the
target** — so the idea is sound.

**Why it is not simply a win.** `llvm-ifs` discards symbol versions, and that silently
disarms this tree's most valuable check. The same `libgreet.so`, built both ways:

```
full sysroot :  CXXABI_1.3  CXXABI_1.3.9  GLIBC_2.17  GLIBCXX_3.4
stub sysroot :                            GLIBC_2.17
```

```
original libc.so.6:   memcpy@@GLIBC_2.17     23 GLIBC_* version definitions
stub:                 memcpy                  0
```

`TARGET_CXXABI_MAX` then has nothing to compare against, `make verify` reports
`RESULT: PASS`, and the binary runs — the loss is invisible from every angle. That is the
"reports PASS for something it had no way to verify" failure the suite already guards against
elsewhere. (The surviving `GLIBC_2.17/2.34` come from the `Scrt1.o`/`crti.o` startup objects,
not from the stub, which is why glibc looks intact while libstdc++ quietly is not.)

**Suggested change.** Opt-in per target, with the ABI-checked libraries never stubbed:

* `libc.so.6`, `libstdc++.so.6`, `libm.so.6`, `libgcc_s.so.1` total **4.9M of 173M**. Keep
  those verbatim, stub the other 156, and you keep nearly all the win with the verifier intact.
* Record the fact in `.crossbuild-sysroot-ready` so `make sysroot-info` can say "link-only:
  this sysroot cannot be used to verify or run anything", the way the linkability warning
  already speaks up about runtime-only rootfs trees.
* Refuse to stub when `TARGET_CXXABI_MAX` or `TARGET_LIBC_VERSION` is set unless the protected
  set is honoured — those fields are a statement that the ceiling matters.

**Note on bandwidth.** `llvm-ifs` runs on the build host, so this saves **disk, not
transfer** — the full library still crosses the wire first. Saving bandwidth would need stubs
generated on the far side, i.e. `llvm-ifs` present on the target, which for a device is
unlikely. Item 1, now done, is the one that saved both.

**Risk:** high if applied bluntly, low if scoped as above. Needs a test asserting that a
stubbed sysroot still produces artifacts whose `GLIBCXX`/`CXXABI` references survive — i.e.
that the protected set really is protected.

---

# Architecture review, 2026-08-13

A read-only pass over the whole tree, looking for places where the design's stated
invariants are not the ones the code actually maintains. Same rules as above: evidence
attached, ordered by (win ÷ risk).

**The verdict first, because the items below are all local repairs, not a redesign.** The
abstraction boundaries are in the right places. One validator with two generated views;
one data→flag site; providers registered by filename with normalisation applied by the
harness; verification tied to named device-side errors; native as an ordinary target rather
than a second code path; `arch-table.sh` failing *closed* on an unknown architecture. Those
are the load-bearing decisions and none of them needs to move.

What follows is the gap between those claims and the implementation.

---

## 8. Two parsers, not one

**Impact:** the highest-value item here. `tools/conf2mk.sh` is documented as the only reader
of a description, and its trailing-comment stripping carries the note that it "MUST happen …
for both views". Six consumers bypass it and parse with raw `sed`: `component-output.sh`,
`order-components.sh`, `doctor.sh`, and four loops in the top-level `Makefile`
(`list-targets`, `list-components`, `list-bundles`, `check`).

**Evidence.** With `COMPONENT_OUTPUT=libzz.so   # the real name` in a component:

```
tools/conf2mk.sh          ->  COMPONENT_OUTPUT ?= libzz.so
tools/component-output.sh ->  libzz.so   # the real name
```

That string becomes an artifact path, a make prerequisite, and — after `patsubst lib%,-l%`
— a `-l` flag. `order-components.sh deps_of` has the same gap in the other direction: words
inside a trailing comment are treated as dependency names, so a comment mentioning a real
component silently adds an edge to the build graph.

This is the same failure class the tree already documents and guards against elsewhere: a
description that is valid for one consumer and quietly wrong for another.

**Suggested change.** Add a single-value query to the existing validator —
`conf2mk.sh --get KEY <file>` — reusing its strip/quote/duplicate rules rather than adding a
seventh parser. Convert all six consumers. Where the call sits inside a Make expansion (once
per dependency edge), read the already-generated `build/generated/.../NAME.sh` when present.

Tests: a trailing comment on `COMPONENT_OUTPUT`, `COMPONENT_DEPENDS` and
`BUNDLE_COMPONENTS`, and a quoted multi-word value, through every list/check path.

**Risk:** low. Behaviour changes only where it is currently wrong.

---

## 9. `make build TARGET=<t>` fails on a clean host

**Impact:** the first substantial command a newcomer runs, and it ends in red.

**Evidence.** On this host, after `make sysroot TARGET=example-native`:

```
built:   hello-world test-greet-lib test-greet-app
skipped (optional, failed):  example-fpga-session example-gpu-coprocessor
                             example-transport-backend example-transport-session
FAILED:  example-device-null example-executor example-runtime-capi
         example-transport-runtime test-cmake-demo
make: *** [Makefile:427: build] Error 1
```

Cause: the shipped example components declare `COMPONENT_SOURCE_ROOTS=CATALYST`, and
`mk/rules.mk` turns an unset root into a hard `$(error)`. `test-cmake-demo` needs cmake.
Neither is available to someone who has just cloned the tree, and both are *examples*
sharing a namespace with user content.

**Suggested change.** When building *all* components, an unset source root (or a missing
cmake) becomes **skipped, with the reason named** — the treatment
`COMPONENT_OPTIONAL=yes` already gets, for the same underlying situation. Keep the hard
error when the component was named explicitly with `COMPONENT=`, since there the user asked
for that specific thing and a skip would be a silent no-op.

Acceptance test: on a host with no `CATALYST` and no `cmake`,
`make build TARGET=example-native` exits 0 and prints what it skipped and why.

Larger version, if the namespace split is wanted: move shipped `example-*` and `test-*`
descriptions into `examples/{targets,components,bundles}/` and discover them through a
search path, leaving `targets/` and `components/` for real work.

**Risk:** low. The skip path already exists and is already reported.

---

## 10. Two flag composers, not one

**Impact:** `docs/03-how-flags-are-derived.md` states that the direct path and the cmake
path "both read the same variables", and that the generated toolchain file is the structural
fix for the old tree's `KEEP IN SYNC` comment. It is only half a fix.

**Evidence.** `tools/gen-cmake-toolchain.sh` does not consume `TARGET_CXX_FLAGS` /
`TARGET_LINK_FLAGS`. It re-derives them from the raw fields:

```
cpu_flag=…      # duplicates derive.mk's _CPU_FLAG
linker_flag=…   #            "         _LINKER_FLAG
stdlib_flag=…   #            "         _STDLIB_FLAG
std_flag=…      #            "         the -std= composition
```

Separately, `-O2 -fPIC` are added in `mk/rules.mk` and nowhere else, so:

* `make show-target` — captioned "These are the exact flags every component gets" — omits
  both;
* cmake-driven components receive neither;
* `-fPIC` is applied to executables as well as shared libraries, where `-fPIE` or nothing is
  the correct choice.

`BUILD_TYPE` is advertised in `config.mk.example` but reaches only cmake, so
`make build BUILD_TYPE=Debug` silently produces an `-O2` build for every direct component.

**Suggested change.** `mk/derive.mk` composes everything, including a new
`TARGET_OPT_FLAGS ?= -O2` honouring `BUILD_TYPE`, and a PIC policy keyed on
`COMPONENT_KIND`. `gen-cmake-toolchain.sh` then consumes the exported flag variables
verbatim and keeps only genuinely cmake-shaped translation: `CMAKE_SYSROOT`, RPATH the cmake
way, the `FIND_ROOT_PATH` modes, and dropping `--target` for a prefixed GCC.

While there: the base flags currently appear twice on every command line (once via
`ALL_CXXFLAGS`, once via `ALL_LDFLAGS`). Harmless, but the printed command line is this
tree's main teaching artifact and it should read cleanly.

Test: for each shipped target, assert the cmake toolchain's flag set is a superset of the
direct path's, and that `show-target` names every flag the recipe actually emits.

**Risk:** low-medium. Flag order is observable; keep the documented precedence chain
(derive < target .conf < component .conf) exactly as it is.

---

## 11. Editing a header does not trigger a rebuild

**Impact:** a stale artifact reported as up to date — which `mk/rules.mk` itself calls "the
worst possible behaviour for a build system, since you then test the old binary believing it
is the new one". That sentence sits in the cmake branch, where the problem was fixed. The
direct paths still have it.

**Evidence.** `$(ARTIFACT)` depends on `$(COMPONENT_SOURCES)`, the two descriptions and the
sysroot stamp. Nothing scans `#include` graphs, and all sources are compiled in a single
compiler invocation, so no `.d` files exist to scan with.

**Suggested change.** Compile per translation unit into `$(OUT_DIR)/obj/` with `-MMD -MP`
and `-include` the generated `.d` files. This also makes real parallelism possible (item 16).

If that is judged out of scope, say so loudly in `mk/rules.mk` and
`docs/05-troubleshooting.md` under "things that fail silently" — where this belongs and is
currently absent. Silence about it is the part that contradicts the rest of the tree.

**Risk:** medium; the largest code change proposed here. Behaviour-preserving if objects
stay under the existing per-component output directory.

---

## 12. A provider argument cannot contain a space

**Impact:** two providers document an argument form that their own parser cannot accept.

**Evidence.** Every provider parses with `for kv in $ARGS`, which word-splits:

```
ARGS='host=u@h paths="/lib /usr/lib"'   ->   [host=u@h]  [paths="/lib]  [/usr/lib"]
```

So `ssh-rsync`'s documented `paths="/lib /usr/lib"` and `debootstrap`'s
`packages="a b c"` both die on the second word as "unrecognised argument". The failure is at
least loud, but the documented syntax simply does not work. Six copies of the same parser
means six places to fix it.

**Suggested change.** One shared `sysroot/providers/_args.sh` with quote-aware parsing, plus
a `--describe` mode per provider listing the keys it accepts. `get-sysroot.sh`'s error path
and a new `make sysroot-help PROVIDER=<x>` can then print that list instead of each provider
restating it in prose.

**Risk:** low. Add tests for a quoted multi-word `paths=` and `packages=` round-trip.

---

## 13. Project-specific knowledge inside the generic engine

**Impact:** the tree is target-agnostic, as claimed. It is not project-agnostic, which the
top-level documentation implies.

**Evidence.** `make catalyst-llvm`, `tools/build-catalyst-llvm.sh`, the `COMPILER_LAUNCHER`
default, `CATALYST` named in `make help`, and the C++20 floor in `mk/derive.mk` justified by
Catalyst's headers — all inside the layer described as "the engine — target-agnostic, you
don't touch it".

**Suggested change.** Keep the *mechanisms*, move the *justifications*. The C++20 floor
becomes `TARGET_CXX_STANDARD_MIN` (default 20) with the Catalyst rationale living in the
example target that needs it. `catalyst-llvm` moves behind a `recipes/` plugin directory
mirroring the providers pattern — filename is registration — or into `examples/catalyst/`.

**Risk:** low, but it is a public-interface change: `make catalyst-llvm` would move or gain
a prefix. Worth doing only alongside item 9's namespace split, if that is taken.

---

## 14. `STRICT=` is honoured by `verify` but not by `bundle`

**Impact:** `make verify STRICT=1` treats warnings as errors; `make bundle` — the step
immediately before deployment, and the one that runs verification on everything it
gathers — has no such option. The stricter gate is on the earlier, less consequential step.

**Suggested change.** Thread `STRICT` through `tools/make-bundle.sh` to each
`verify-artifact.sh` call. One line each side.

**Risk:** none, if it stays opt-in.

---

## 15. Builds are serial, and that is not stated anywhere

**Impact:** `make build` is a shell `for` loop over components, and each component is one
compiler invocation. `JOBS` reaches only cmake components. On a multi-component tree this is
the dominant cost, and nothing in the documentation says so.

**Suggested change.** Depends on item 11: once objects and `.d` files exist,
`order-components.sh` can emit Make *prerequisites* rather than a linear order, and the
whole graph builds under `-j`. Until then, state the limitation in `mk/rules.mk` beside the
existing explanation of why each component gets its own sub-make.

**Risk:** medium (same change as item 11). Stating it costs nothing.

---

## 16. Repository hygiene and fact drift

**Impact:** small individually; together they undercut a tree whose argument is that
duplicated facts drift.

**Evidence.**

* `README.md` says the suite is 113 tests, `TLDR.md` says 106; an actual run reports
  106 passed / 0 failed / 3 skipped.
* `examples/docker/` is linked from both `README.md` and `TLDR.md` and is untracked.
* `TLDR.md` and this file are untracked, and `README.md` links both.
* Four `targets/example-native.conf.bak.*` files were committed. `.gitignore` covers
  `targets/probe-*.conf` but not the `*.conf.bak.*` pattern that `probe-over-ssh.sh`
  actually writes, so every probe of an existing target leaves a new one.

**Suggested change.** Write probe backups to `build/target-backups/<name>.<timestamp>.conf`
— generated files belong under `build/`, which the tree already defines as disposable — and
add the pattern to `.gitignore` for the ones already in the wild. Track or delete the three
untracked paths. Remove hardcoded counts from prose; `tests/run-tests.sh` already prints its
own.

**Risk:** none.

---

## 17. Three near-synonym verbs, and the least-tested code in the tree

**Impact:** discoverability, and one genuine testing gap.

**Evidence.** `make validate` (descriptions parse), `make check` (validate plus reference
cross-checks) and `make test` (the suite) are three commands whose distinction has to be
read to be understood. Separately, the target-resolution block in the `Makefile` — nested
`ifeq`, parse-time `$(shell)`, `$(origin)`-based override plumbing, and a goal-scoped
`exports.mk` include that exists solely to dodge Make's re-expansion of inherited
environment values (the `$ORIGIN` → `RIGIN` bug) — is the densest logic in the tree and is
reachable only through end-to-end goals.

**Suggested change.** Fold `validate` into `check`, keeping `validate` as an alias. Extract
the resolution block into `mk/resolve.mk` and test it directly against fixture descriptions.
Consider one `make status TARGET=<t>` that answers what `show-target`, `sysroot-info` and
"what is built" answer separately today.

**Risk:** low.

---

## 18. One rationale, told eight times

**Impact:** the *why*-first commenting is this tree's best feature and its main maintenance
cost. The VPK120 story — eight Makefiles, the drifted `-static-libstdc++`, the `KEEP IN
SYNC` comment — is retold in `README.md`, `TLDR.md`, all three `SCHEMA.md` files,
`mk/derive.mk`, `mk/rules.mk`, `tools/conf2mk.sh` and `docs/06`. Eight variants of one
argument will drift, which is precisely the thesis.

**Suggested change.** One canonical home (`docs/06`, with `docs/01` for the concepts).
Everywhere else: one sentence and a link. Adopt a convention in code — `WHY: <one line>
(see docs/0X#anchor)`.

**Keep the verbatim error snippets.** The blocks quoting real compiler and loader output are
the highest-value content in the tree and are not duplication; it is the surrounding
narrative that repeats.

Make the remaining claims testable rather than asserted:

* a test asserting every key documented in each `SCHEMA.md` appears in `conf2mk.sh`'s arrays
  and vice versa — today a comment merely *asks* that they not drift;
* a test asserting every `make` goal named in the documentation still exists.

**Risk:** none.

---

## 19. No CI, no shellcheck, no way to run one test

**Impact:** the suite exists and passes, and nothing enforces that it keeps passing. The
tree is bash-critical and unlinted.

**Suggested change.** A workflow running `make doctor`, `make check` and
`tests/run-tests.sh`, with a matrix leg that has no clang so the GCC path stops being
SKIP-only. `shellcheck` over `tools/` and `sysroot/providers/`. A `-k <pattern>` filter for
`run-tests.sh`, and a split of its 1056 lines into sourced section files.

**Risk:** none.

---

## Suggested order

| | item | effort | risk |
|---|---|---|---|
| 0 | **20e — the doc lint** | ~hour | none |
| 1 | 16 — hygiene and drift | minutes | none |
| 2 | **8 — one parser** | ~half day | low |
| 3 | **9 — skip, do not fail, on a missing source root** | ~hour | low |
| 4 | 10 — one flag composer | ~day | low-med |
| 5 | 18 — documentation consolidation (parallelisable) | ~day | none |
| 6 | 12 — provider argument parsing | ~half day | low |
| 7 | 14, 17 — surface cleanup | ~half day | low |
| 8 | 19 — CI | ~half day | none |
| 9 | 11 + 15 — objects, header deps, parallelism | ~2 days | medium |
| 10 | 13 — Catalyst out of the engine | ~day | low, but public interface |
| 11 | **20a–d — the verbosity trim, file by file** | ~2 days | see item 20 |

Items 8 and 9 are the two that change how the tree feels; everything else is repair.

The doc lint (20e) is listed at 0 because it is cheap and because every documentation item
after it — 13, 18 and 20a–d — is otherwise re-litigated by hand each time someone edits a
file. Run 20a–d last: it is mostly deletion, and deleting before 8, 10 and 13 have moved code
around means doing it twice.

## Not to be changed

Recorded because they look like candidates for simplification and are not:

* the verbatim observed-error comments, and the test names that state which failure they
  prevent;
* `mk/component.mk`'s one-process-per-component variable isolation;
* native as an ordinary target — never reintroduce a second code path;
* `.conf` files as inert data, with no command substitution;
* `arch-table.sh` failing closed on an unknown architecture.

## Decisions this review could not make

1. ~~Is this primarily a teaching artifact or a production build system?~~ **Answered: a
   production build system, published, read by external users.** That settles the framing for
   item 20 and raises the bar for items 13 and 18 — anything that only means something to
   someone who worked on the predecessor comes out. It also means item 11 should be judged on
   build correctness and speed rather than on how well the recipes read as a worked example.
2. Does Catalyst stay first-class (item 13), or move behind a plugin directory?
3. Do shipped examples keep sharing a namespace with user content (item 9)?
4. ~~Who is the primary reader?~~ **Answered: an external user of a released tool.** The
   documentation may still teach cross-compilation — `TLDR.md` and `docs/01` are the right
   places for that — but the code comments must stop teaching and start specifying. See
   item 20 for the threshold and the lint.

---

# Host-portability pass, 2026-08-14

Running the tree on a second kind of build host — macOS, bash 3.2, BSD userland, Mach-O
artifacts — turned up defects that had nothing to do with macOS and everything to do with
facts the engine assumed rather than asked. All are fixed. They are recorded because the
*shape* of each one recurs, and because most of them were silent: the tree reported success
while checking nothing.

Measured on macOS as the port landed: **73 passed / 30 failed → 132 passed / 0 failed /
3 skipped**, stable across repeated runs. Per item 16 the count lives here, in a dated
entry, and not in the user-facing prose.

---

## 24. A description parser that truncated its output and exited 0

**Shape:** a partial result indistinguishable from a whole one, so every consumer downstream
accepted it and no consumer could have known.

**Evidence.** `tools/conf2mk.sh` stripped surrounding quotes with `${val:1:-1}`. A negative
substring length needs bash 4.2; macOS ships 3.2.57 as `/bin/bash`, where it aborts the read
loop with

```
conf2mk.sh: line 298: -1: substring expression < 0
```

so the parse stopped at the first quoted value, emitted a one-key file, and **exited 0** —
every setting after that point silently reverted to its default while the build receipt still
named the description as their source.
`make validate` reported every description in the tree valid on a host where the parser was
failing on every one of them.

**Fixed.** The length is spelled arithmetically, plus a structural guard that does not depend
on knowing the cause: a completion marker as the last line of both generated views, a
`conf2mk.sh --check <file>` mode that verifies it, a captured loop exit status, and a
lines-read count. Every consumer now runs `--check` on what it just generated — the
top-level `Makefile` twice, `mk/component.mk` twice, and `tools/load-conf.sh`.

**Why the marker alone was not enough**, which is the part worth keeping: a bash expansion
error inside `while read … done < file` abandons the **loop** and resumes after it with
status 0, and `set -e` does not fire. So the exit status the consumers already tested proved
nothing, and the loop's own status is what catches this class. The marker covers a signal or
a full disk; the line count covers whatever neither does.

---

## 25. Two gates that printed ok having verified nothing

**Shape:** a regular expression that cannot match, inside code whose output is a PASS. A
fail-open, and both instances sat on the checks `AGENTS.md` requires before claiming a change
works.

**Evidence.** The `Makefile`'s `check` goal extracted bundle references with
`sed 's/^BUNDLE_\(OPTIONAL_\)\?COMPONENTS=//p'`. `\?` is a GNU BRE extension; BSD sed reads
it as a literal `?`, so the pattern matched **neither** real key, the reference list was
always empty, the inner loop never ran, and the goal printed

```
  ok    every reference resolves
```

having checked zero references. Measured: a bundle pointing at `no-such-component-at-all`
passed.

The same construct (`\(UN\)\?`) in `tools/verify-artifact.sh` made the RPATH variable come
back empty on any BSD userland, so the empty-entry hazard, the leaked-build-host-path warning
and the mangled-`$ORIGIN` detector all had nothing to look at — the verifier printed
`RPATH: none set` for a binary with an RPATH.

**Fixed.** Both halves of `check` read values through `conf2mk.sh --shell` and `eval`, which
also gets them quote stripping and trailing-comment stripping (item 8's defect, in the goal
that is supposed to catch it). The verifier uses two `-e` expressions instead of one optional
group.

---

## 26. A required tool named by its binary, not by the job it does

**Shape:** a capability check that hardcodes one implementation, so a host that can do the
job is told it cannot — or a host that has the toolchain is assumed to have all of it.

**Evidence.** `tools/doctor.sh` demanded `readelf` unconditionally, so a Mac that could
build, verify and bundle its own artifacts perfectly was told
`VERDICT: 1 required tool(s) missing — cross-building will not work yet` and exited
non-zero. Reporting
a non-gap as a blocker trains people to ignore the tool.

Two more of the same shape:

* `mk/derive.mk` assumed the LLVM prefix ships the whole `llvm-*` suite. Apple's Command Line
  Tools — which `detect-host.sh` correctly reports — have `clang`, `clang++` and `llvm-nm`
  and **not** `llvm-ar`, `llvm-ranlib`, `llvm-strip`, `llvm-readelf` or `llvm-objcopy`.
* `sysroot/providers/dir` and `ssh-rsync` passed `rsync --info=progress2`, which needs
  rsync 3.1+. macOS 15 replaced Samba rsync with openrsync (protocol 29), which rejects it —
  so a sysroot fetch failed over a progress bar.

**Fixed.** `doctor.sh` asks which formats the described targets actually span and checks a
reader for each, looks inside Homebrew's keg-only `llvm` prefix before declaring `readelf`
absent, and reports the bash and make in use as host facts. `derive.mk` falls back to the
plain tool name. The progress flag is probed once and dropped when absent. Also gone:
doctor's three ad-hoc `sed` description readers, one of which suppressed the "ABI ceiling
check is disabled" warning for any description carrying a trailing comment on that line.

---

## 27. Errors that became data, and errors nobody read

**Shape:** an unchecked command substitution whose *failure text* is used as a value; and a
diagnostic printed so often it reads as noise.

**Evidence.** `tools/detect-host.sh` used `paste -sd-` with no file operand. GNU paste reads
stdin then; BSD paste prints its usage and exits 1 — so the function returned

```
usage: paste [-s] [-d delimiters] file ...
```

as though it were a triple. That value became `TRIPLE_ALT` in `tools/sysroot-inspect.sh` and
was used to build candidate directory names, so a sysroot's multiarch directory was never
found, the `-isystem` and `-B` flags were simply absent, and the consequence surfaced two
layers later as a missing `bits/c++config.h`.

`tools/order-components.sh` used `declare -A`, which bash 3.2 rejects — and then falls back
to indexed-array semantics, evaluating the subscript as arithmetic:

```
order-components.sh: line 40: declare: -A: invalid option
order-components.sh: line 46: example: unbound variable
```

printed before `make help` had said anything, on **every** goal in the tree.

Same class, quieter: four unguarded empty-array expansions in `tools/make-bundle.sh` (bash
before 4.4 treats an empty array under `set -u` as unbound and aborts, and one of them was
inside the redirected group that writes `BUNDLE-RECEIPT.txt`, so it truncated the receipt
mid-file), and `tools/load-conf.sh` discarding the exit status of sourcing the generated view.

**Fixed.** A trailing `-` names stdin explicitly, which GNU paste accepts too. The DFS
visited-set is the space-delimited-string idiom `conf2mk.sh` already uses for duplicate keys.
`${arr[@]+"${arr[@]}"}` at each expansion. The status kept and checked.

---

## 28. A fixture that could only pass on its author's machine

**Shape:** a suite that measures the host rather than the code, and then blames the code.

**Evidence.** Every build-requiring test built against `test-native-gcc`, which names
`x86_64-linux-gnu`, an `x86_64-linux-gnu-` prefixed gcc, `bfd`, and
`/lib64/ld-linux-x86-64.so.2` — all properties of one particular laptop. On anything else,
including aarch64 **Linux**, 22 tests failed for that single reason, and they failed by
reporting defects all over the build system:

```
FAIL  an executable component builds
FAIL  the built binary actually RUNS
FAIL  a bundle assembles with all its components
```

Two smaller ones in the same suite. The arch-mismatch fixture chose aarch64-vs-x86_64
from `uname -m`, which reports `arm64` on Darwin and `aarch64` on Linux for the same chip —
and `arch-table.sh` maps both to `AArch64`, so the "mismatch" fixture named the same machine
and the test could not fail. And two rebuild tests compared mtimes with `-nt`, which bash and
make compare at whole-second granularity, so a correct reconfigure landing inside the same
second read as a reused cache.

**Fixed.** The suite generates `test-host-native` from the host at start-up and removes it on
exit, every host-specific field blank — which is the schema's "ask the host". `test-native-gcc.conf`
stays as the `TOOLCHAIN_KIND=gcc` example and now says it assumes an x86_64 Linux host.
Portable stand-ins replace the GNU-only tools the suite itself used: `with_timeout` (no
coreutils `timeout`), `edit_in_place` (no in-place `sed` — BSD `sed -i` requires an argument
and reads the expression as a backup suffix, leaving the file untouched), and `make_old`,
because relative `touch -d` is GNU-only and failed with

```
touch: out of range or illegal time specification: YYYY-MM-DDThh:mm:SS[.frac][tz]
```

leaving the mtime alone, so four rebuild tests were asserting nothing. Two static scanners now
fail if a bash-4-only or GNU-only construct is reintroduced into the engine, with a self-test
proving the scanners still match planted constructs.

---

## 29. `--disable-new-dtags` composed in two places, only one of which had learned

**Shape:** the duplication this tree exists to remove, found the way duplication is always
found — one copy was told something and the other was not.

**Evidence.** `mk/derive.mk` is documented as the only place data becomes compiler flags, but
`tools/gen-cmake-toolchain.sh` composed the rpath link flags itself (item 10 states the
general case). `derive.mk` learned that ld64 rejects the flag; this file did not, so every
cmake component failed on macOS at the compiler-probe stage with

```
ld: unknown options: --disable-new-dtags
The C++ compiler ... is not able to compile a simple test program
```

which reads as a broken clang install rather than as one flag from one line in a generated
toolchain file.

**Fixed.** Both places branch on the same exported `TARGET_BINFMT`. That is a repair, not the
cure: item 10 (one flag composer, with the cmake file consuming `TARGET_LINK_FLAGS` verbatim)
is the change that makes this unrepeatable. Item 10 recorded the first cost of the same
split — `-O2 -fPIC` never reaching the cmake path, `BUILD_TYPE` never reaching the direct
one — and this is the second.
