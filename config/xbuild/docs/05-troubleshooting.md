# 5. Troubleshooting — indexed by the message you actually saw

Cross-compilation errors are notorious for not naming their cause. This page is
organised by the *text you saw*, because that is what you have.

---

## Runtime errors on the target

### `cannot execute binary file: Exec format error`

**Cause:** wrong architecture. The binary's machine type does not match the CPU.

**Catch it earlier:** `make verify TARGET=<t>` reports this on the build host.

**Fix:** check `TARGET_TRIPLE` and `TARGET_ARCH` in the description.
`make show-target TARGET=<t>` shows what is actually being used. If a native
compiler was picked up instead of a cross one, `make doctor` will show which
toolchain was found.

---

### `No such file or directory` — on a file that plainly exists

You can `ls` it. You can `chmod +x` it. The shell still says this.

**Cause:** the **ELF interpreter** path baked into the binary does not exist on the
target. The missing file is the loader, not your binary. This is the single most
confusing error in cross-compilation.

**Confirm it:**

    readelf -l ./mybinary | grep interpreter     # what the binary wants
    ssh target 'ls -l /lib/ld-linux-aarch64.so.1' # is it there?

**Fix:** find the real path on the target and set it:

    ssh target 'readelf -l /bin/sh | grep interpreter'
    # then in targets/<t>.conf:
    TARGET_DYNAMIC_LINKER=/lib/ld-linux-aarch64.so.1

Debian multiarch uses `/lib/<triple>/ld-linux-<arch>.so.1`; Yocto-derived and many
other embedded roots use `/lib/ld-linux-aarch64.so.1`; musl uses
`/lib/ld-musl-<arch>.so.1`. They are all different, and guessing does not work.

**Catch it earlier:** `make verify` compares the binary's interpreter against
`TARGET_DYNAMIC_LINKER` and fails on a mismatch.

---

### `version 'GLIBC_2.38' not found (required by ./libfoo.so)`

**Cause:** built against a newer glibc than the target has.

**Fix, in order of preference:**

1. Rebuild the sysroot from the actual target — then there is nothing to guess:

       # in the description
       SYSROOT_PROVIDER=ssh-rsync
       SYSROOT_PROVIDER_ARGS="host=user@target"

       make sysroot-clean TARGET=<t> && make sysroot TARGET=<t>

2. If the sysroot is already correct, then `TARGET_LIBC_VERSION` is wrong. Re-run
   `make probe TARGET=<t> SSH=user@target`.

**Catch it earlier:** this is exactly what `make verify` checks. If it did not
catch it, `TARGET_LIBC_VERSION` is empty — `make show-target` says so explicitly.

---

### `version 'GLIBCXX_3.4.32' not found`

Same as above, for libstdc++.

**Three options:**

1. **Ship the library** (usually best): `BUNDLE_SYSROOT_LIBS=libstdc++.so.6` in the
   bundle, with `TARGET_RPATH=$$ORIGIN`. The copy is taken from the sysroot, so it
   is the library you actually linked against.
2. `COMPONENT_STATIC_CXX=yes` — only for a leaf artifact. Read the warning in
   `components/SCHEMA.md` first: two static C++ runtimes in one process is a bug
   class you do not want.
3. Build against an older sysroot.

---

### `error while loading shared libraries: libfoo.so: cannot open shared object file`

**Cause:** the library is not where the loader looks.

**Check what the binary expects:**

    readelf -d ./mybinary | grep -E 'NEEDED|RPATH|RUNPATH'

**Fixes:**

* The library should be in the bundle → add its component to `BUNDLE_COMPONENTS`.
  `make bundle` warns about exactly this case: it lists any `NEEDED` library that
  is neither in the bundle nor in the sysroot.
* The RPATH is missing → confirm `TARGET_RPATH=$$ORIGIN` in the description.
* You see `RUNPATH` rather than `RPATH` and a *transitive* dependency fails →
  `DT_RUNPATH` does not apply to a library's own dependencies. This tree passes
  `--disable-new-dtags` to get `DT_RPATH`; if a cmake project overrode it, that is
  the cause.

---

### `dyld[NNN]: Library not loaded: @rpath/libfoo.dylib`

The Mach-O counterpart of the entry above, and the most dangerous message on this
page, because everything before it succeeded: the link, any check that asks only "is
an rpath present", and an `ls` of the directory, which shows the library sitting right
beside the binary. Read the `Reason:` line, where the mistake finally becomes visible:

    dyld[63195]: Library not loaded: @rpath/libfoo.dylib
      Referenced from: <...> /tmp/example-native/mybinary
      Reason: tried: '$ORIGIN/libfoo.dylib' (no such file), '$ORIGIN/libfoo.dylib' (no such file)

**Cause:** `TARGET_RPATH=$$ORIGIN` on a Mach-O target. `$ORIGIN` is the *ELF*
spelling of "next to this file"; dyld expands `@loader_path` and `@executable_path`
and nothing else. `ld64` does not reject the token it cannot use — it writes it into
`LC_RPATH` verbatim — so nothing fails until run time, and then the loader reports
searching a directory literally named `$ORIGIN`.

**Fix:** leave `TARGET_RPATH` blank. `mk/derive.mk` fills in the token the target's
format uses: `$$ORIGIN` for ELF, `@loader_path` for Mach-O. Set it explicitly only to
say something other than "beside the binary".

**Catch it earlier:** `make verify TARGET=<t>` fails on an `LC_RPATH` containing
`$ORIGIN` and says that dyld does not understand that token. This one is an error
rather than a warning precisely because the linker's silence is the whole problem —
see also `03-how-flags-are-derived.md`.

---

### `Illegal instruction` / SIGILL, on some machines but not others

**Cause:** `TARGET_CPU` is set to something newer than the machine you ran on. The
compiler emitted instructions that CPU does not have.

**Fix:** clear `TARGET_CPU` in the description. Generic code runs everywhere. Only
set a CPU when the entire fleet is that exact part.

---

## Build-host errors

The entries that follow are the tree's own tools meeting a userland that is not GNU's —
a BSD `sed`, `touch`, `paste` or `rsync`, or the bash 3.2.57 that macOS still ships as
`/bin/bash`.

All of them are fixed here, so on a current checkout you should not meet any of them.
They are documented anyway, and first, for the two situations where you still can: an
older checkout, and a change that reintroduces one. Most corrupted a value rather than
stopping, which is why they lead — a wrong value shows up later as something else, so
anything further down this page can be a symptom of one of these. Three static scanners
in `tests/run-tests.sh` fail if such a construct comes back.

---

### `conf2mk.sh: line NNN: -1: substring expression < 0`

**Cause:** a bash older than 4.2 meeting `${value:1:-1}` — a *negative* substring
length, which 4.2 introduced. `make doctor` prints the interpreter in use under
`build host`.

**Why it was worse than it looks:** a bash expansion error inside
`while read … done < file` abandons the *loop* and resumes after it with status 0, and
`set -e` does not fire. So the description was truncated at its first quoted value,
`conf2mk.sh` exited 0, and every setting after that point silently fell back to its
default. `make validate` reported all 24 shipped descriptions valid on a host where
the parser was failing on every one of them.

**Fixed**, and guarded so that a partial parse can no longer pass for a complete one:
the generated view ends with a completion marker, `conf2mk.sh --check <file>` verifies
it, and every consumer runs `--check` on what it just generated. The parser also
captures the loop's exit status and counts the lines it read, and emits *nothing* for a
partial parse:

    <file>: parsing stopped after line N of M — the output is TRUNCATED.

If you see that message, the cause is whatever was printed on the line above it.

---

### `declare: -A: invalid option`, then `example: unbound variable`

Two errors on **every** make invocation, before it does anything:

    order-components.sh: line 40: declare: -A: invalid option
    order-components.sh: line 46: example: unbound variable

**Cause:** an associative array, which needs bash 4.0. On 3.2 the declaration fails
*and* the subscript is then evaluated as arithmetic, so a component name becomes an
undefined variable — hence the second, unrelated-looking message.

**Fixed:** the DFS visited set is two space-delimited strings, the idiom
`conf2mk.sh` already used.

---

### `usage: paste [-s] [-d delimiters] file ...` — where a triple should be

Nothing failed at that point. The usage text *became* the value.

**Cause:** `tools/detect-host.sh` assembled the alternative triple with `paste -sd-`
and no file operand. GNU paste reads stdin then; BSD paste does not — it prints its
usage and exits 1.

**What it cost:** that string was `TRIPLE_ALT`, from which `sysroot-inspect.sh` builds
multiarch directory names. No such directory was ever found, so the `-isystem` and
`-B` flags were simply absent, and the failure surfaced thousands of lines later as a
missing `bits/c++config.h` (see below) — that is, as a broken sysroot.

**Fixed:** a trailing `-` names stdin explicitly, which GNU paste accepts too, so one
spelling works on both.

---

### `touch: out of range or illegal time specification` / `sed: 1: "<file>": …`

Both come from `tests/run-tests.sh` on a BSD userland, and both mattered for the same
reason: the tool failed, so the file was left **unchanged**, and the test that went on
to assert against the result measured the original.

**`touch -d '-1 hour'`** is a GNU relative-date form with no BSD equivalent:

    touch: out of range or illegal time specification: YYYY-MM-DDThh:mm:SS[.frac][tz]

(that is BSD touch printing the format it *would* accept, not your argument). Four
rebuild tests aged an artifact that way, so they were really asserting "make rebuilt
something that was already newer" and reported the build system as broken.

**`sed -i`** takes no argument in GNU sed and *requires* one in BSD sed, so BSD sed
read the expression as the backup suffix and then tried to parse the file path as the
script. So the quoted text is the *file name* — followed by its newline, which is why
the message breaks across two lines — and what follows varies with the path you edited:

    sed: 1: "sysroot.conf
    ": unterminated substitute pattern
    sed: 2: "targets/t-std.conf
    ": undefined label 'argets/t-std.conf'

**Fixed:** `make_old` uses the POSIX `touch -t 200001010000` — the tests need "older
than what we touch next", not any particular age — and `edit_in_place` writes a temp
file and moves it. Both behave identically everywhere.

---

### `unrecognized option '--info=progress2'` from rsync during `make sysroot`

    rsync: unrecognized option `--info=progress2'

**Cause:** that flag needs rsync 3.1+ and macOS 15 replaced Samba rsync with
openrsync (`rsync --version` reports `openrsync: protocol version 29`), which rejects
it — so an entire sysroot fetch failed over a progress display.

**Fixed:** the `dir` and `ssh-rsync` providers probe for the flag once and drop it
when it is absent; see `04-sysroot-providers.md`.

---

### `could not unpack the data archive from <package>` (provider `deb`)

A truncated or corrupt download, usually. It is transient and the archive is re-fetched from
scratch, so run the same command again:

    make sysroot TARGET=<name>

The message now includes what `tar` actually said, which is what distinguishes a bad download
from a full disk or a permission problem. (It used to discard that, leaving only the sentence
above — which named a package and no cause, and gave no hint that retrying was the answer.)

---

### `bundle assembled at … but one or more artifacts FAILED verification`

One of the gathered artifacts cannot load on the target. The specific mismatch — architecture,
interpreter path, or a libc/libstdc++ symbol newer than the target provides — is printed above
this line, per artifact.

The artifacts are deliberately left on disk so you can inspect them, but the bundle is closed
to deployment: a `VERIFICATION-FAILED.txt` is written beside them, the receipt is stamped, and
both `make deploy` and the bundle's own `deploy.sh` refuse while that file is present. If you
have genuinely decided to ship something that did not verify, deleting that one file is how
you say so.

Do not fix this by deleting it casually. Fix the mismatch, then re-run `make bundle`, which
removes the marker on success.

---

### `these dependencies are in neither the bundle nor the sysroot`

A library the artifact records as `NEEDED` was found nowhere the build system can see. It is a
WARNING, not a failure, because the target may legitimately have it — but nothing here checked
the target, so it is a guess.

Resolve it rather than shipping on the guess: add the component that produces it to
`BUNDLE_COMPONENTS`, or name the library in `BUNDLE_SYSROOT_LIBS` so it is copied in.

The generated `deploy.sh` repeats this list, because that script is what travels with the
bundle and is read on the far end.

---

### `this host is <arch> and cannot run aarch64 binaries` (`make pseudo-remote`)

The container is a genuinely foreign architecture for this machine and the kernel has no
emulator registered for it:

    docker run --privileged --rm tonistiigi/binfmt --install arm64

Or use a same-architecture box, which is faster and teaches less:

    make pseudo-remote PLATFORM=linux/amd64

This is now asked only when the container really is foreign. It used to be asked on every
host by reading `/proc/sys/fs/binfmt_misc/`, a Linux-only path — so on any Mac the check could
not succeed, and an Apple Silicon laptop, where `linux/arm64` is *native*, was told it could
not run aarch64 binaries.

---

### `docker is installed but no daemon is responding`

The CLI installs on its own; the daemon is separate. Start Docker Desktop, or `colima start`,
or `systemctl start docker`, then retry. `make doctor` reports this under sysroot providers,
and distinguishes it from docker being absent.

---

### `sysroot directory does not exist`

Run `make sysroot TARGET=<t>`. Which provider that uses comes from
`SYSROOT_PROVIDER`; see `04-sysroot-providers.md`.

---

### `make sysroot` printed `sysroot ready`, but `build/sysroots/<target>/` is not there

**Cause:** unknown. Observed once, on a first run in a freshly-cleaned tree, and not
reproducible afterwards in repeated attempts from the same starting state.

**Fix:** run `make sysroot TARGET=<name>` again. The second run succeeds and the tree is
correct from then on.

It is recorded here rather than left out because the next symptom is
`ERROR: sysroot directory does not exist`, which reads as though the command was never run —
and somebody who *did* run it, and watched it report success, will reasonably go looking for
a deeper problem instead of simply repeating it.

---

### `'<dir>' exists but contains no C library, so it cannot be a sysroot`

The message lists every path it searched, and the filenames it searched *for* — which
depend on the target's binary format: `libc.so*`, `libc.a` or `ld-musl-*.so*` for ELF,
and `libSystem.tbd`, `libSystem.B.tbd`, `libc.tbd` or `libSystem.dylib` for Mach-O.

**Causes, most likely first:**

* The provider copied a subdirectory rather than the rootfs root. A sysroot's top
  level contains `usr/` and `lib/`. For the `tar` provider try `strip=1`.
* An interrupted fetch: `make sysroot-clean TARGET=<t> && make sysroot TARGET=<t>`.
* `TARGET_TRIPLE` does not match the tree's layout.

**On a Mac, none of those three is the cause.** Since Big Sur the system libraries
have no on-disk files at all — they exist only inside the dyld shared cache — so `/`
genuinely contains no C library, and what you link against is a tree of `.tbd` text
stubs in the SDK. If you reached this message with `SYSROOT_PROVIDER=dir` and `path=/`,
the answer is `SYSROOT_PROVIDER=native`, which asks `xcrun --show-sdk-path` where the
SDK is and symlinks it; see `04-sysroot-providers.md`.

---

### `fatal error: 'debug/assertions.h' file not found`

Reported from inside libstdc++, typically at
`bits/stl_iterator_base_funcs.h:65`, on **every** C++ compile.

**This is not a toolchain problem.** `debug/assertions.h` is a required part of
libstdc++'s headers — `<string>` pulls it in transitively — so the message means
your sysroot's C++ header tree is **missing a subdirectory**:

    <sysroot>/usr/include/c++/<ver>/debug/

**Cause:** the copy that produced the sysroot excluded it. The classic mistake is a
pattern meaning "skip the split-debug symbols in `/usr/lib/debug`" written
*unanchored*. An rsync pattern with no leading `/` matches a basename at **any
depth**, so `--exclude 'debug/'` also deletes the C++ `debug/` directory:

    --exclude 'debug/'      # WRONG: every directory named debug, anywhere
    --exclude '/debug/***'  # right: only <transfer-root>/debug

The same trap applies to `doc/`, `man/` and `locale/`.

**Fix:**

1. Check `SYSROOT_PROVIDER_ARGS exclude=` in your target description for any pattern
   without a leading `/`, and anchor it. `make sysroot` warns about unanchored
   user-supplied patterns.
2. Re-fetch:

       make sysroot-clean TARGET=<t> && make sysroot TARGET=<t>

`make sysroot` now validates the C++ header tree and reports this directly, naming
the missing file and the likely exclude, instead of letting the failure surface
inside a system header.

> Note: the shipped `ssh-rsync` provider had exactly this bug in its own default
> exclude list. If you are on an older copy of this tree, update
> `sysroot/providers/ssh-rsync` — its patterns should all begin with `/` (except
> `*.debug` and `__pycache__/`).

**Why this was worth a dedicated check:** it is a *silent-wrongness* failure one step
removed. The copy succeeded, the sysroot looked complete, `libc` was present, and the
error appeared thousands of lines deep in someone else's header — the least
informative place it could have surfaced.

---

### `fatal error: 'vector' file not found` (or `'stdio.h' file not found`)

**Cause:** the sysroot has no C++ headers where the compiler looked.

**Diagnose:**

    make sysroot-info TARGET=<t>

If it reports `c++ hdrs: none`, the sysroot has no C++ headers at all — you copied
a runtime rootfs without `-dev` packages. Either copy `/usr/include` too (the
`ssh-rsync` provider does by default) or install the dev packages on the target
first.

---

### `bits/c++config.h: No such file or directory`

**Cause:** the arch-independent C++ headers were found but the arch-specific ones
were not. `sysroot-inspect.sh` adds both `-isystem` paths when they exist, so this
means the second genuinely is not in the sysroot — usually a partial copy.

---

### `TARGET_SYSROOT_GCC_VERSION=13 was requested but ... does not exist`

Your pin is stale. The message lists the versions that *are* present. Either update
the pin or remove it — with no pin, the newest present is used, which is normally
what you want.

---

### `ld64.lld: error: unknown argument '--disable-new-dtags'` (also `'-soname'`, `'-rpath-link'`)

**Cause:** an ELF-only linker flag reaching a Mach-O linker. Each is a GNU-ld spelling
of something Mach-O either does differently or does not need at all:

* `--disable-new-dtags` asks for `DT_RPATH` rather than `DT_RUNPATH`. `LC_RPATH`
  already applies to transitive loads the way `DT_RPATH` does, so there is nothing to
  choose between.
* `-soname` records a shared library's identity. Mach-O spells that `-install_name`,
  and the tree prefixes it `@rpath/` so a bundle stays relocatable.
* `-rpath-link` is a build-time-only search path for transitive dependencies. A dylib
  records the install name of everything it links, so the linker follows those instead.

**Fixed:** all three now branch on `TARGET_BINFMT`, derived from the triple in
`mk/derive.mk`. `make show-target TARGET=<t>` prints the exact flags you got and
`make sysroot-info TARGET=<t>` reports the resolved `format`;
`03-how-flags-are-derived.md` explains the split. Note that `-shared` needs no branch —
clang maps it to `-dynamiclib` on a Mach-O target already.

**The cmake face of the same flag.** `--disable-new-dtags` was composed in
`tools/gen-cmake-toolchain.sh` as well as in `derive.mk` — the duplication this tree
exists to remove — and only `derive.mk` had learned that ld64 rejects it. So every
`COMPONENT_KIND=cmake-project` failed at the compiler probe with

    ld: unknown options: --disable-new-dtags
    The C++ compiler ... is not able to compile a simple test program

which reads as a broken clang install rather than as one flag from one line of a
generated file. Both places now branch on the same exported `TARGET_BINFMT`.

---

### `warning: include path for libstdc++ headers not found`, then `fatal error: 'string' file not found`

The full first line is

```
clang++: warning: include path for libstdc++ headers not found; pass '-stdlib=libc++'
         on the command line to use the libc++ standard library instead
```

and on a link-only failure you may see `ld: library 'stdc++' not found` instead.

**Cause:** `TARGET_STDLIB=libstdc++` on a Mach-O target. macOS has no libstdc++ at
all — clang's C++ library there is libc++. The flag is *not* rejected: `libstdc++` is a
name clang implements, so it is accepted, nothing is found, and the failure arrives as a
missing standard header. That is why it reads as a broken sysroot rather than as one
field in a description. (The `invalid library name` error belongs to a different mistake:
`-stdlib=` misspelt as a name clang does not implement at all.)

**Fix:** leave `TARGET_STDLIB` blank. `mk/derive.mk` fills it from the target's binary
format: libstdc++ for ELF, libc++ for Mach-O. `targets/example-native.conf` leaves it
blank for exactly this reason, so one description works on both kinds of machine.

Related, and reported as its own error rather than as three driver messages naming
flags: `COMPONENT_STATIC_CXX=yes` cannot be honoured on a Mach-O target either, because
`-static-libstdc++` and `-Wl,--exclude-libs` are GNU-ld only and Darwin ships no static
libc++. `mk/rules.mk` refuses it by name, naming the component and the target.

---

### `FAILED: example-executor` — and `make` exits `Error 1` after a build that otherwise worked

You ran `make build TARGET=<t>` with **no `COMPONENT=`**, so it built every described
component. Most succeeded; the summary lists them under `built:`. But a bare build also
attempts `example-executor`, which links a cross-built LLVM that is not present unless you ran
`make catalyst-llvm`, so it fails — and one failed component fails the whole goal, even though
everything you actually wanted is built and fine.

Name what you want instead of building everything:

    make build TARGET=<t> COMPONENT=<name>
    make list-components                      # what exists, and what each one needs

If you genuinely want `example-executor`, build its LLVM first: `make catalyst-llvm TARGET=<t>
CATALYST=<dir>` (about an hour). Most work on this tree never needs it.

---

### `No rule to make target '.../runtime/lib/.../<something>.cpp'`

Naming a source file under your `CATALYST` path. `CATALYST` points at a directory that
*exists* but is not a Catalyst checkout — or is the wrong one — so a source the build expects
under it is not there. (Contrast the two adjacent cases: an *unset* `CATALYST` gives the
"needs the source root" error below; a *nonexistent path* gives "source root … does not
exist". This message is the "exists but wrong tree" case, and it is the one INSTALL.md warns
about because it points at a missing file rather than at the root.)

    make show-component TARGET=<t> COMPONENT=<c> CATALYST=<dir>   # prints the paths it resolved

Check that the printed `sources:` paths exist. Usually `CATALYST` is a sibling checkout, or a
release tarball missing the `runtime/` sources.

---

### `Component 'x' needs the source root 'CATALYST', which is not set`

Pass it, or set it once:

    make build TARGET=<t> CATALYST=/path/to/checkout
    # or
    cp config.mk.example config.mk && $EDITOR config.mk

Note that `make show-component`, which the error invites you to run, refuses to run under
this same condition — it needs the root resolved before it can print the `-I` paths. It
becomes useful once `CATALYST` points *somewhere*; use it when the path exists but you
suspect it is the wrong checkout.

---

### `clang++: error: invalid linker name in argument '-fuse-ld=lld'`

`lld` is not installed, or not on `PATH`. Every ELF target here links with it
(`TARGET_LINKER=lld` — set explicitly by most descriptions here, and the derived default for any ELF
target under an llvm toolchain), and the compiler driver reports the name it was handed
without saying which package provides it.

    brew install lld          # macOS — a SEPARATE formula from llvm
    apt install lld           # Debian / Ubuntu
    dnf install lld           # Fedora

On macOS this catches people out: `brew install llvm` provides `lldb`, the debugger, and no
linker at all. Unlike `llvm`, `lld` is not keg-only — after installing it, `ld.lld` is on
`PATH` at `/opt/homebrew/bin/ld.lld` with no `export` needed.

`make doctor` reports this before you hit it, and names the targets that need it.

---

### `verify-artifact: found a readelf, but it cannot list dynamic symbols`

The reader on `PATH` does not understand `--dyn-syms`, which all three ABI ceiling checks
read. `eu-readelf` (elfutils) is the usual cause — it spells this `--symbols`.

This is deliberately fatal rather than skipped. An unrecognised option produces no output,
and no output is indistinguishable from "this artifact imports no versioned symbols" — so
accepting it would report `PASS` having checked nothing, in the one check that exists to stop
a binary the target cannot load.

    apt install binutils | brew install llvm

---

### `verify-artifact: no readelf found`

Verification cannot read the ELF headers, so it fails rather than passing something it did
not check. Nothing is wrong with your artifact — the check simply did not happen.

On macOS the only `readelf` is inside Homebrew's llvm, which is keg-only, so installing it
does not put it on `PATH`:

    brew install llvm
    export PATH="$(brew --prefix llvm)/bin:$PATH"

On Debian/Ubuntu or Fedora: `apt install binutils` / `dnf install binutils`.

The binary there is spelled `llvm-readelf`; there is no plain `readelf` in that directory.
The tree probes for `llvm-readelf`, `readelf`, `eu-readelf` and `<host-triple>-readelf`, so
any one of them is enough — but a bare `readelf` typed by hand after that export will still
say "command not found".

`make doctor` reports this before you hit it. If it is already installed but off `PATH`,
doctor says so by name and prints the exact `export`, rather than reporting a tool it can
see but the build cannot use.

---

### `is marked COMPONENT_REQUIRES_NATIVE=yes, but target ... is <triple> while this host is <triple>`

That component uses a vendor compiler (HIP/CUDA) that cannot cross-compile. Build
it on a machine of the target architecture, or drop it from that target's bundle —
put it in `BUNDLE_OPTIONAL_COMPONENTS` so its absence is not an error.

---

### `unknown key 'TARGET_TRIPPLE'`

A typo. Rejected deliberately rather than ignored — an ignored typo leaves a
default silently in place and you debug the default instead of the typo. Legal keys
are in `targets/SCHEMA.md`.

---

### `'$(...)' is not allowed in a TARGET description`

Target descriptions are read directly by shell (the sysroot providers source
them), where `$(...)` executes a command. Compute the value elsewhere and pass it
on the command line.

Component descriptions *may* use `$(VAR)` — they are only ever read by Make — but
only bare variable references, not `$(shell ...)` or `$(wildcard ...)`.

---

### `relocate-symlinks: cannot rewrite ...: Read-only file system`

The sysroot is read-only (a mounted SDK, a shared cache). Either switch to
`SYSROOT_PROVIDER=dir` with `mode=copy` to get a writable snapshot, or
`SYSROOT_PROVIDER=none` to declare that the tree is managed externally and must not
be touched.

---

### cmake: `Exec format error` during `configure`

**Cause:** cmake tried to *run* a test binary it built for the target.

**Fix:** `CMAKE_CROSSCOMPILING TRUE` prevents this and the generated toolchain file
always sets it. If you are seeing this, the project is probably being configured
without the generated toolchain file — check that `COMPONENT_KIND=cmake-project`
and that the build used `build/<target>/toolchain.cmake`.

---

### cmake finds the build host's libraries

**Cause:** `find_library` searched outside the sysroot.

**Fix:** the generated toolchain file sets
`CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY` (and the same for INCLUDE and PACKAGE)
to prevent this. If a project overrides those, that is the cause. Note the
deliberate exception: for a **native** target the restrictions are relaxed, since
"the host" and "the target" are the same machine.

---

### A cmake-built artifact has no RPATH

**Cause:** CMake owns the RPATH of everything it links and discards `-Wl,-rpath`
passed in linker flags.

**Fix:** the generated toolchain file sets `CMAKE_BUILD_WITH_INSTALL_RPATH TRUE`
and `CMAKE_INSTALL_RPATH` for this reason. This was a real bug found by the test
suite; the test `the cmake artifact gets the target's RPATH` guards it.

---

### `The link interface of target "LLVMSupport" contains: ZLIB::ZLIB but the target was not found`

Also seen with `zstd::libzstd_shared` or `Terminfo::terminfo`, and always at *configure*
time, pointing inside LLVM's own `LLVMExports.cmake`.

**Cause:** that LLVM was built with the optional dependency enabled, so its exported targets
reference an imported target which only exists if something calls `find_package(ZLIB)`.
`LLVMConfig.cmake` does call it — but not `REQUIRED`, so when it finds nothing the failure is
silent and only surfaces later as a target nobody wrote. It finds nothing because the
generated toolchain sets `CMAKE_FIND_ROOT_PATH_MODE_*` to `ONLY` (correct for cross builds),
and the sysroot has no `zlib.h` / `libz.so` — the runtime `libz.so.1` alone is not enough.

**Fixes, in order of preference:**

1. Install the `-dev` package on the target and re-fetch: `apt install zlib1g-dev`, then
   `make sysroot TARGET=<t>`. `make sysroot-info TARGET=<t>` will warn when a sysroot can be
   run against but not linked against.
2. Build the LLVM you link with those options OFF. `make catalyst-llvm` does this
   deliberately (`LLVM_ENABLE_ZLIB=OFF` and friends) so that consuming it needs nothing in
   the sysroot beyond libc and libstdc++.

---

### `no template named 'CWrapperFunctionResult'` / `'llvm/ExecutionEngine/Orc/...' file not found`

**Cause:** the wrong LLVM *version*. Catalyst's executor source compiles against LLVM 20–22
only: below 20 the ORC headers it includes do not exist yet, and 23 renamed
`CWrapperFunctionResult` to `CWrapperFunctionBuffer`. Picking "the newest LLVM installed" is
how you get this.

**Fix:** `cmake/CrossbuildFindLLVM.cmake` reads `LLVM_VERSION_MAJOR` out of each
candidate `LLVMConfig.cmake` and refuses anything outside the window, naming what it found.
Point it at a supported one with `-DLLVM_DIR`, or build Catalyst's own pinned LLVM.

---

### `No LLVM found in the sysroot` when cross-compiling a component that links LLVM

**Cause:** a component like `example-executor` runs *on the target* — it is an ORC EPC
executor that JITs code there — so it must link target-architecture LLVM libraries.
Catalyst's `mlir/llvm-project/build` is a build-host build; linking those into an aarch64
binary fails inside lld with `incompatible with elf64-littleaarch64`.

**Fix:** cross-build the LLVM Catalyst pins, once per target:

```
make catalyst-llvm TARGET=<t> CATALYST=/path/to/catalyst
```

That produces `build-<arch>/` beside Catalyst's host build, reusing the host build's
`llvm-tblgen` (a cross build needs a tablegen that runs *here*) and `ccache` when installed,
matching `catalyst/mlir/Makefile`'s `COMPILER_LAUNCHER`. Components find it automatically —
the architecture is in the directory name for exactly that reason.

Installing a distro `llvm-<N>-dev` in the target's rootfs is the tempting shortcut and is
usually the wrong version: Ubuntu 24.04 offers up to LLVM 20 while Catalyst tracks 22. Since
ORC's wire protocol is not guaranteed stable across majors, a mismatch builds and deploys
cleanly and then fails when the two ends connect.

---

## Things that fail *silently* — check for these deliberately

The dangerous failures produce no message. Look for them on purpose.

**A same-architecture cross build that used host libraries.** Cross-compiling
x86-64→x86-64 with a different libc: nothing errors, and the binary may be subtly
wrong. Guard: keep `TARGET_LIBC_VERSION` set and run `make verify`.

**A build-host path in RPATH.** Harmless until the day it is not, and then the
error names a directory from someone's laptop. Guard: `make verify` warns;
`--strict` fails.

**A stale artifact in a bundle.** An ABI change between artifacts built weeks apart
returns wrong answers rather than erroring. Guard: `BUNDLE-RECEIPT.txt` records
what went in and when; rebuild the whole bundle when in doubt.

**An absolute device-library path compiled into an artifact.** If a program
`dlopen`s an absolute path, no amount of bundling helps — it ignores the copy beside
it. `make bundle` reports what each artifact needs but does not claim to have
satisfied it, precisely because it cannot.

---

## Diagnostic commands worth knowing

    make doctor                       # can this host cross-compile? what is missing?
    make show-target TARGET=<t>       # every resolved value + the exact flags
    make sysroot-info TARGET=<t>      # what the sysroot actually contains
    make verify TARGET=<t> STRICT=1   # strictest ABI check
    make show-component TARGET=<t> COMPONENT=<c>   # that component's exact command line
    make test                         # is the build system itself sound?

    readelf -h <file>                 # architecture, ELF class
    readelf -l <file> | grep interp   # ELF interpreter
    readelf -d <file>                 # NEEDED, RPATH, RUNPATH, SONAME
    readelf --dyn-syms <file> | grep GLIBC_   # symbol versions required

    otool -hv <file>                      # architecture (Mach-O header)
    otool -l <file> | grep -A2 LC_RPATH   # rpath entries
    otool -L <file>                       # what it needs, by install name
    otool -D <file>                       # this dylib's own install name (the SONAME counterpart)

Neither reader understands the other's format, and a host legitimately has one, the
other, or both: `readelf` ships with binutils (or LLVM), `otool` with the Xcode Command
Line Tools. `make doctor` reports which of the two it found and demands only the ones
your described targets actually span — and note that `otool -hv` prints `ARM64` where
`readelf -h` says `AArch64` for the same chip.
