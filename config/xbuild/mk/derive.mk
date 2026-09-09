# ─────────────────────────────────────────────────────────────────────────────
# mk/derive.mk — the single place where target DATA becomes compiler FLAGS.
#
# This file is the load-bearing wall of the design. Everything above it (target
# .conf files) is data; everything below it (components) consumes only the
# variables defined here and never inspects the target's identity. That is the
# interface/implementation split the redesign is about:
#
#     a component may ask "what are my CXXFLAGS?"
#     a component may NOT ask "am I building for the my-board target?"
#
# A build that names its machines in component recipes needs one rule per
# (component × target), and those copies drift: one gets -static-libstdc++ and the
# others do not, for no recorded reason, and nothing announces the difference until
# a binary misbehaves on one device. Here there is exactly one definition of each
# flag, and components are target-agnostic by construction — they *cannot* drift,
# because there is nothing to copy.
#
# Read docs/03-how-flags-are-derived.md for a narrative walkthrough with the
# resolved output for each shipped example target.
# ─────────────────────────────────────────────────────────────────────────────

# ── 0. Guard against double inclusion ────────────────────────────────────────
ifndef DERIVE_MK_INCLUDED
DERIVE_MK_INCLUDED := 1

ifndef TARGET_NAME
  $(error mk/derive.mk included without a target. Include build/targets/<name>.mk first, \
          or invoke via the top-level Makefile with TARGET=<name>.)
endif

# A literal comma, so it can be used inside $(if ...) calls where an unescaped
# comma would be parsed as an argument separator. Defined before first use.
COMMA := ,

ROOT_DIR    ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
BUILD_DIR   ?= $(ROOT_DIR)/build
TARGET_BUILD_DIR := $(BUILD_DIR)/$(TARGET_NAME)
TOOLS_DIR   := $(ROOT_DIR)/tools

# ── 1. Fill in defaults for anything the description left blank ──────────────
#
# Every default here is documented in targets/SCHEMA.md with its rationale. The
# principle: a default must be the *safe* choice, not the convenient one. A
# generic-CPU binary that runs everywhere beats a tuned binary that SIGILLs on
# half the fleet, so TARGET_CPU defaults to empty.

# GPU_ARCH= on the command line overrides the description's TARGET_GPU_ARCH, so a
# one-off build for another card needs no edit to a committed file. The override is
# named GPU_ARCH rather than TARGET_GPU_ARCH because a command-line TARGET_GPU_ARCH
# would be immutable here and could not be reported against the description.
#
# There is deliberately no fallback to whatever GPU this machine has. The build host
# need not hold the coprocessor's card, or any card, so detecting locally would
# silently produce a bundle that runs nowhere useful. Unset is an error at the
# component that needs it, not a guess.
ifneq ($(strip $(GPU_ARCH)),)
  TARGET_GPU_ARCH := $(GPU_ARCH)
endif

# The architecture is the first field of the triple, which is true for every
# triple form in practice (arch-vendor-os-abi, or arch-os-abi).
ifeq ($(strip $(TARGET_ARCH)),)
  TARGET_ARCH := $(firstword $(subst -, ,$(TARGET_TRIPLE)))
endif

ifeq ($(strip $(TARGET_TRIPLE)),)
  # A native target may leave the triple blank; ask the host compiler what it is.
  # This is why example-native.conf works unchanged on an arm64 laptop.
  TARGET_TRIPLE := $(shell $(TOOLS_DIR)/detect-host.sh triple)
  ifeq ($(strip $(TARGET_TRIPLE)),)
    $(error TARGET_TRIPLE is empty and could not be detected from the host compiler. \
            Set it explicitly in $(TARGET_CONF_FILE).)
  endif
  # Only derive the arch if the description did not state one. Overwriting an explicit
  # TARGET_ARCH here would silently discard it — and TARGET_ARCH is what the ABI
  # verifier checks the binary's machine type against, so discarding it weakens a
  # safety check without saying anything.
  ifeq ($(strip $(TARGET_ARCH)),)
    TARGET_ARCH := $(firstword $(subst -, ,$(TARGET_TRIPLE)))
  endif
endif

# ── the target's binary format ───────────────────────────────────────────────
#
# Read from the triple through tools/arch-table.sh, which owns every platform fact, so
# that supporting a new platform stays a data change there rather than a conditional here.
#
# This exists because a handful of the flags composed below are ELF concepts with no
# Mach-O equivalent, and passing them anyway does not fail quietly:
#     ld64.lld: error: unknown argument '--disable-new-dtags'
#     ld64.lld: error: unknown argument '-soname'
# while one of them — an rpath of $ORIGIN — IS accepted by the Mach-O linker and written
# into LC_RPATH verbatim, where the loader never expands it. That last one is the reason
# this is a derived fact and not left to each description: a wrong rpath token produces a
# binary that links, verifies and then cannot find its own libraries at run time.
TARGET_BINFMT := $(shell $(TOOLS_DIR)/arch-table.sh binfmt $(TARGET_TRIPLE))

# Defaults for keys that may be present-but-empty.
#
# '?=' does NOT fire for a key that was assigned an empty value, and every key in a
# generated .mk IS assigned — so `TARGET_STDLIB=` (documented as meaning "use the
# default") would reach the comparison below as empty and hard-error. Testing for
# emptiness handles both "absent" and "explicitly blank", which is what the schema
# promises.
#
# The libc and C++ library defaults follow the FORMAT, because the ELF answers are not
# merely unusual on Darwin, they do not exist there: the system C library is libSystem
# (shipped as a .tbd stub in the SDK, with no libc.so anywhere), and there is no
# libstdc++ at all. clang ACCEPTS -stdlib=libstdc++ there — it is a name it implements —
# and then nothing is found, so the failure arrives as a missing header rather than as a
# rejected flag:
#     clang++: warning: include path for libstdc++ headers not found; pass '-stdlib=libc++'
#              on the command line to use the libc++ standard library instead
#     fatal error: 'string' file not found
# which reads as a broken sysroot rather than as one field in a description.
ifeq ($(strip $(TARGET_LIBC)),)
  ifeq ($(TARGET_BINFMT),macho)
    TARGET_LIBC := libSystem
  else
    TARGET_LIBC := glibc
  endif
endif
ifeq ($(strip $(TARGET_ENDIAN)),)
  TARGET_ENDIAN := little
endif
ifeq ($(strip $(TOOLCHAIN_KIND)),)
  TOOLCHAIN_KIND := llvm
endif
ifeq ($(strip $(TARGET_STDLIB)),)
  ifeq ($(TARGET_BINFMT),macho)
    TARGET_STDLIB := libc++
  else
    TARGET_STDLIB := libstdc++
  endif
endif
ifeq ($(strip $(TARGET_CXX_STANDARD)),)
  TARGET_CXX_STANDARD := 20
endif

# ── C++20 is a FLOOR, not just a default ─────────────────────────────────────
# The code this tree builds needs it: Catalyst's headers use C++20 concepts
# (mlir/include/Driver/Timer.h declares `concept IsRatio = requires {...}`) and
# catalyst/runtime/CMakeLists.txt sets CXX_STANDARD 20 REQUIRED. Compiled as C++17 the
# failure is `error: unknown type name 'concept'` inside a vendor header, which reads as
# a broken checkout rather than as one line in a target description.
#
# Enforced here rather than left to each description because descriptions are GENERATED:
# sysroot/probe/probe-target.sh writes a whole file from a machine probe, and it cannot
# know what standard the SOURCE needs. Every regeneration reset a hand-edited 20 back to
# 17 and the failure returned. A floor in the one place every target passes through
# cannot be undone by regenerating a file.
#
# A blacklist of the pre-20 spellings, not a whitelist of allowed ones: the set of
# standards older than C++20 is closed and will never grow, so a future 26 or 32 passes
# through untouched instead of being "raised" to 20.
_CXX_PRE20 := 98 03 0x 11 1x 14 1y 17 1z
ifneq ($(filter $(strip $(TARGET_CXX_STANDARD)),$(_CXX_PRE20)),)
  $(info note: $(TARGET_NAME) asks for C++$(strip $(TARGET_CXX_STANDARD)); raised to C++20, the minimum this tree supports (see mk/derive.mk).)
  TARGET_CXX_STANDARD := 20
endif
# The token meaning "the directory this file was loaded from". Both formats have one and
# they are spelled differently; neither loader understands the other's. Written out here
# rather than fetched from arch-table.sh so the doubled '$$' stays visible and reviewable
# in the one place it matters — a single '$' here becomes the literal string 'RIGIN'.
ifeq ($(strip $(TARGET_RPATH)),)
  ifeq ($(TARGET_BINFMT),macho)
    TARGET_RPATH := @loader_path
  else
    TARGET_RPATH := $$ORIGIN
  endif
endif
ifeq ($(strip $(TARGET_DEPLOY_DIR)),)
  TARGET_DEPLOY_DIR := /tmp/$(TARGET_NAME)
endif
ifeq ($(strip $(SYSROOT_PROVIDER)),)
  SYSROOT_PROVIDER := none
endif

# -mcpu vs -march is architecture-dependent and getting it wrong is a hard error,
# not a warning: clang rejects -mcpu= for x86 outright. Defaulting per-arch means
# a new board on a known architecture needs no thought here at all.
# Read from tools/arch-table.sh rather than keeping a second copy of the arch list
# here. One table, three consumers (this file, the verifier, the debootstrap provider),
# so adding an architecture stays a data change.
ifeq ($(strip $(TARGET_CPU_FLAG)),)
  TARGET_CPU_FLAG := $(shell $(TOOLS_DIR)/arch-table.sh cpu-flag $(TARGET_ARCH))
endif

# lld is the right default when cross-linking ELF: it needs no per-target binutils, which
# is most of why one clang can serve every target here.
#
# It is NOT the right default for Mach-O. ld64 is the platform linker on Darwin, is always
# present with the Command Line Tools, and is the configuration Apple tests; lld's Mach-O
# backend works but is an extra dependency for no gain on a native build. Requiring it
# would mean a stock Mac could not build until somebody installed LLVM separately, which
# is the kind of hidden prerequisite this file exists to remove.
ifeq ($(strip $(TARGET_LINKER)),)
  ifneq ($(TOOLCHAIN_KIND),llvm)
    TARGET_LINKER := bfd
  else ifeq ($(TARGET_BINFMT),macho)
    TARGET_LINKER := default
  else
    TARGET_LINKER := lld
  endif
endif

# ── 2. Locate the sysroot ────────────────────────────────────────────────────
# Default location keeps every generated thing under build/, so `rm -rf build`
# is a complete reset and nothing generated is ever mistaken for source.
ifeq ($(strip $(SYSROOT_DIR)),)
  SYSROOT_DIR := $(BUILD_DIR)/sysroots/$(TARGET_NAME)
endif

# The marker file that means "this sysroot is real". Autodetected rather than
# hardcoded, because the old design's hardcoded probe —
#   usr/lib/aarch64-linux-gnu/libc.a
# — is a *Debian multiarch* path AND a static-library path. A musl root, a Yocto
# SDK, a Fedora root, or any rootfs copied off a real device that ships only
# shared libraries all fail that test while being perfectly good sysroots. The
# system would then tell you to "run install.sh", which was the wrong advice.
SYSROOT_STAMP := $(SYSROOT_DIR)/.crossbuild-sysroot-ready

# ── 3. Locate the toolchain ──────────────────────────────────────────────────
# The message for a missing LLVM toolchain, as a define block so the newlines
# actually survive into the output. A $(error) with backslash-continued lines
# collapses them into one unreadable paragraph, which defeats the purpose of writing
# a careful message.
define NO_LLVM_MSG
No LLVM toolchain found for target '$(TARGET_NAME)'.

  This target sets TOOLCHAIN_KIND=llvm, but no 'clang' was found on PATH and
  TOOLCHAIN_ROOT is not set.

  Fix by any one of:
    * install clang        apt install clang lld  |  dnf install clang lld
    * point at an install  make ... TOOLCHAIN_ROOT=/opt/llvm-19
    * use GCC instead      set TOOLCHAIN_KIND=gcc in the target description
                           ($(TARGET_CONF_FILE))

  'make doctor' reports everything this host has and what is missing.
endef

ifeq ($(TOOLCHAIN_KIND),llvm)

  ifeq ($(strip $(TOOLCHAIN_ROOT)),)
    # `clang -print-resource-dir` yields <root>/lib/clang/<ver>; strip back to <root>.
    # Asking the compiler beats guessing /usr/lib/llvm-18, which is a Debian-only
    # path that does not exist on Fedora, Arch, macOS, or a self-built LLVM.
    TOOLCHAIN_ROOT := $(shell $(TOOLS_DIR)/detect-host.sh llvm-root)
  endif

  # Refuse to proceed with an empty root. Without this guard every tool path becomes
  # "/bin/clang++" (an empty prefix plus "/bin/..."), and the build fails much later
  # with "make: /bin/clang++: No such file or directory" — which reads as though the
  # build system expected clang in a strange place, rather than "you have no clang".
  # Naming the actual problem, and both ways out of it, costs four lines here and
  # saves a genuinely confusing debugging session.
  ifeq ($(strip $(TOOLCHAIN_ROOT)),)
    $(error $(NO_LLVM_MSG))
  endif

  # An LLVM prefix does not necessarily ship the whole llvm-* suite, and the most common
  # one on a Mac does not: Apple's Command Line Tools — which is exactly what
  # detect-host.sh llvm-root correctly reports there — provide clang, clang++ and llvm-nm
  # and none of llvm-ar, llvm-ranlib, llvm-strip, llvm-readelf or llvm-objcopy.
  #
  # Naming them unconditionally built paths to files that are not there, and the
  # consequences appeared a long way from this line: `make bundle` with BUNDLE_STRIP=yes
  # reported "no strip tool found; shipping unstripped" on a host that has strip, and
  # TARGET_READELF arrived at the bundler as a path to nothing.
  #
  # So ask the filesystem, and fall back to the plain name the platform does provide.
  # $(wildcard) on a path containing no wildcard returns it when it exists and nothing
  # when it does not, which is precisely the test wanted.
  _llvm_tool = $(if $(wildcard $(TOOLCHAIN_ROOT)/bin/llvm-$(1)),$(TOOLCHAIN_ROOT)/bin/llvm-$(1),$(1))

  TARGET_CC      := $(TOOLCHAIN_ROOT)/bin/clang
  TARGET_CXX     := $(TOOLCHAIN_ROOT)/bin/clang++
  TARGET_AR      := $(call _llvm_tool,ar)
  TARGET_RANLIB  := $(call _llvm_tool,ranlib)
  TARGET_STRIP   := $(call _llvm_tool,strip)
  # readelf has no plain counterpart on Darwin. The fallback name is still emitted, and
  # every consumer probes it with `command -v` before use, so an absent one degrades to
  # their own reader hunt rather than to a hard failure.
  TARGET_READELF := $(call _llvm_tool,readelf)
  TARGET_NM      := $(call _llvm_tool,nm)
  TARGET_OBJCOPY := $(call _llvm_tool,objcopy)

  # One clang emits every architecture it was built with, so the target is
  # selected by a flag rather than by a different binary. This is the property
  # that makes an LLVM toolchain the sane default for a multi-target tree.
  _TRIPLE_FLAG := --target=$(TARGET_TRIPLE)

else ifeq ($(TOOLCHAIN_KIND),gcc)

  TOOLCHAIN_PREFIX ?= $(TARGET_TRIPLE)-
  _BINDIR := $(if $(strip $(TOOLCHAIN_ROOT)),$(TOOLCHAIN_ROOT)/bin/,)

  TARGET_CC      := $(_BINDIR)$(TOOLCHAIN_PREFIX)gcc
  TARGET_CXX     := $(_BINDIR)$(TOOLCHAIN_PREFIX)g++
  TARGET_AR      := $(_BINDIR)$(TOOLCHAIN_PREFIX)ar
  TARGET_RANLIB  := $(_BINDIR)$(TOOLCHAIN_PREFIX)ranlib
  TARGET_STRIP   := $(_BINDIR)$(TOOLCHAIN_PREFIX)strip
  TARGET_READELF := $(_BINDIR)$(TOOLCHAIN_PREFIX)readelf
  TARGET_NM      := $(_BINDIR)$(TOOLCHAIN_PREFIX)nm
  TARGET_OBJCOPY := $(_BINDIR)$(TOOLCHAIN_PREFIX)objcopy

  # GCC is built for one target; the triple is baked into the binary name, so
  # there is no flag to pass. Passing one would be an error.
  _TRIPLE_FLAG :=

else
  $(error TOOLCHAIN_KIND='$(TOOLCHAIN_KIND)' is not supported. Use 'llvm' or 'gcc'.)
endif

# ── 4. Compose the flags ─────────────────────────────────────────────────────
# Composed once, consumed by both the direct-compiler path and the generated
# cmake toolchain file. This is the fix for the old "KEEP IN SYNC" comment: there
# is now nothing to keep in sync, because cmake's toolchain file is *generated
# from these variables* by tools/gen-cmake-toolchain.sh.

_CPU_FLAG := $(if $(strip $(TARGET_CPU)),-$(TARGET_CPU_FLAG)=$(TARGET_CPU),)

_SYSROOT_FLAG := --sysroot=$(SYSROOT_DIR)

ifeq ($(TARGET_LINKER),lld)
  _LINKER_FLAG := -fuse-ld=lld
else ifeq ($(TARGET_LINKER),bfd)
  _LINKER_FLAG := -fuse-ld=bfd
else ifeq ($(TARGET_LINKER),gold)
  _LINKER_FLAG := -fuse-ld=gold
else ifeq ($(TARGET_LINKER),mold)
  _LINKER_FLAG := -fuse-ld=mold
else ifeq ($(TARGET_LINKER),default)
  # 'default' means: pass no -fuse-ld at all and let the compiler driver pick. This is a
  # real choice and not an absence of one — on Darwin the driver's answer (ld64) is both
  # correct and always installed, so naming an alternative would add a prerequisite
  # without improving the link. It is also the escape hatch for any toolchain whose
  # linker this list does not know about.
  _LINKER_FLAG :=
else
  $(error TARGET_LINKER='$(TARGET_LINKER)' is not supported. \
    Use lld, bfd, gold, mold, or 'default' to let the compiler driver choose.)
endif

ifeq ($(TARGET_STDLIB),libc++)
  _STDLIB_FLAG := -stdlib=libc++
else ifeq ($(TARGET_STDLIB),libstdc++)
  # For clang against a GCC-based sysroot, clang must be told where that sysroot's
  # GCC lives. Discovered at build time by tools/sysroot-inspect.sh rather than
  # hardcoded: the old tree pinned GCC_VERSION ?= 13, so a sysroot holding GCC 12
  # or 14 failed with a missing-header error that named no version and gave no hint.
  _STDLIB_FLAG :=
else
  $(error TARGET_STDLIB='$(TARGET_STDLIB)' is not supported. Use libstdc++ or libc++.)
endif

# The interpreter path. Only emitted when the description pins one, because when
# it does not, the compiler's own sysroot-derived default is correct and
# overriding it would make things worse.
_DYNLINK_FLAG := $(if $(strip $(TARGET_DYNAMIC_LINKER)),-Wl$(COMMA)--dynamic-linker=$(TARGET_DYNAMIC_LINKER),)

# --disable-new-dtags asks for DT_RPATH rather than DT_RUNPATH. The distinction
# matters: DT_RUNPATH does not apply to a library's own transitive dependencies,
# so a bundle where liba.so needs libb.so beside it resolves under RPATH and fails
# under RUNPATH. This is the single most common "works on my machine, missing
# library on the target" cause in a self-contained bundle.
#
# It is an ELF concept and a GNU-ld spelling. Mach-O has no DT_RPATH/DT_RUNPATH
# distinction to choose between — its LC_RPATH already behaves the way DT_RPATH does for
# transitive loads — so there is nothing to ask for, and asking is fatal:
#     ld64.lld: error: unknown argument '--disable-new-dtags'
ifeq ($(TARGET_BINFMT),macho)
  _RPATH_FLAG := $(if $(strip $(TARGET_RPATH)),-Wl$(COMMA)-rpath$(COMMA)'$(TARGET_RPATH)',)
else
  _RPATH_FLAG := $(if $(strip $(TARGET_RPATH)),-Wl$(COMMA)-rpath$(COMMA)'$(TARGET_RPATH)' -Wl$(COMMA)--disable-new-dtags,)
endif

# ── how a shared library names itself ────────────────────────────────────────
# Called as $(call TARGET_SONAME_FLAG,<name>) by the shared-library recipe in
# mk/rules.mk, so that the recipe stays one recipe and this stays the only file that
# knows what a linker wants to hear.
#
# ELF records a SONAME; anything linking against the library copies that string and looks
# for it at run time. Mach-O records an install name for the same purpose, and '-soname'
# is not a spelling it accepts:
#     ld64.lld: error: unknown argument '-soname'
# The @rpath/ prefix is what makes the install name relocatable — without it the recorded
# name is the absolute path of the build directory, which is the Mach-O form of exactly
# the leaked-build-host-path problem the verifier reports for ELF RPATHs.
#
# '-shared' is deliberately NOT branched: clang maps it to -dynamiclib on a Mach-O target
# already, so the recipe needs no conditional for it.
ifeq ($(TARGET_BINFMT),macho)
  TARGET_SONAME_FLAG = -Wl$(COMMA)-install_name$(COMMA)@rpath/$(1)
  TARGET_SHLIB_SUFFIX := .dylib
else
  TARGET_SONAME_FLAG = -Wl$(COMMA)-soname$(COMMA)$(1)
  TARGET_SHLIB_SUFFIX := .so
endif

# The public flag variables. Components use ONLY these.
#
# Ordering matters and is deliberate: machine selection, then sysroot, then
# standard, then the description's extra flags LAST so a target can override a
# default we chose here. A component's own flags come after these again, so the
# precedence chain reads: derive.mk < target .conf < component .conf.
TARGET_BASE_FLAGS := $(_TRIPLE_FLAG) $(_CPU_FLAG) $(_SYSROOT_FLAG) $(_LINKER_FLAG)

# Used by mk/rules.mk for C sources. Kept distinct from the C++ set because a C
# compiler rejects -std=gnu++NN and -stdlib=.
TARGET_CC_FLAGS   := $(TARGET_BASE_FLAGS) $(TARGET_CFLAGS)

# The C++ standard is a property of the SOURCE, not of the machine. Named apart from the
# machine flags so mk/rules.mk can withhold those from a native component and still keep this,
# and exported so tools/gen-cmake-toolchain.sh emits the same spelling.
TARGET_STD_FLAG   := -std=gnu++$(TARGET_CXX_STANDARD)

# ── optimisation level ───────────────────────────────────────────────────────
# Composed HERE, and before the description's own flags, for two reasons that are the same
# reason: this is a latency-critical tree, and the -O level of the hot path must be both
# visible and overridable.
#
# It used to be a bare '-O2' literal inside mk/rules.mk, appended AFTER the target's flags.
# Two consequences, both quiet. A board saying TARGET_CXXFLAGS=-O3 was silently defeated —
# clang takes the last -O it sees — while `make show-target` printed the -O3 and never
# printed the -O2 that actually won, under a caption reading "These are the exact flags
# every component gets". And a recipe literal is not a flag anyone can find: it appears in
# no introspection goal and in no description.
#
# '?=' so a command line can pin it for one build without editing anything, and placed
# ahead of TARGET_CXXFLAGS and COMPONENT_CXXFLAGS so the documented precedence
# (derive.mk < target .conf < component .conf) is the real one.
TARGET_OPT_FLAGS ?= -O2

TARGET_CXX_FLAGS  := $(TARGET_BASE_FLAGS) $(_STDLIB_FLAG) \
                     $(TARGET_STD_FLAG) $(TARGET_OPT_FLAGS) $(TARGET_CXXFLAGS)
TARGET_LINK_FLAGS := $(TARGET_BASE_FLAGS) $(_DYNLINK_FLAG) $(_RPATH_FLAG) $(TARGET_LDFLAGS)

# ── 4a. GPU vendor, and the dialect its compiler speaks ──────────────────────
# The architecture names its vendor unambiguously: AMD spells a card 'gfx<n>', NVIDIA spells
# a compute capability 'sm_<n>'. So the vendor is DERIVED rather than asked for, and one
# component description serves both cards. The alternative was a second component .conf
# holding a duplicate copy of the same ten source paths — and a stale copy of that very list
# is how the first version of the GPU coprocessor shipped with no device code in it at all.
#
# Empty for an unset arch, and empty for an arch matching neither spelling. mk/rules.mk
# refuses on the empty flag rather than inventing one from a name it does not recognise.
ifneq ($(filter gfx%,$(TARGET_GPU_ARCH)),)
  TARGET_GPU_VENDOR := amd
else ifneq ($(filter sm_%,$(TARGET_GPU_ARCH)),)
  TARGET_GPU_VENDOR := nvidia
else
  TARGET_GPU_VENDOR :=
endif

# How each vendor's driver wants to be told the architecture. AMD takes the name as it
# stands. NVIDIA wants it twice — a virtual architecture and a real one — and deriving the
# 'compute_NN' half from 'sm_NN' is precisely why this is a make variable and not a literal
# in the description: tools/conf2mk.sh permits only a bare $(NAME) reference in a .conf
# value, so no derivation can happen there.
#
# This flag belongs on the LINK line as well as the compile line. Without it there, an
# NVIDIA artifact gains a stray sm_52 cubin beside the real ones, nvcc having fallen back to
# its own default architecture for the device link it was not told the architecture for.
# Keyed on the derived VENDOR, not on "is it nvidia, else assume AMD": an unrecognised
# spelling must leave this empty so mk/rules.mk can refuse by name. Defaulting it to the AMD
# form instead would hand hipcc '--offload-arch=<typo>' and make that refusal unreachable.
ifeq ($(TARGET_GPU_VENDOR),nvidia)
  TARGET_GPU_ARCH_FLAG := -gencode arch=compute_$(patsubst sm_%,%,$(TARGET_GPU_ARCH)),code=$(TARGET_GPU_ARCH)
else ifeq ($(TARGET_GPU_VENDOR),amd)
  TARGET_GPU_ARCH_FLAG := --offload-arch=$(TARGET_GPU_ARCH)
else
  TARGET_GPU_ARCH_FLAG :=
endif

# The three spellings nvcc does not share with the rest of this tree. A component compiling
# device code gets these in place of the ordinary ones; every other component is untouched.
#
# -std      nvcc implements the standard but not the GNU dialect NAME: 'gnu++20' is refused
#           outright ("Value 'gnu++20' is not defined for option 'std'"). It is also the
#           FIRST thing nvcc refuses, which is why the architecture flag looked like the
#           blocking one for so long and was not.
# soname,   hipcc rewrites '-Wl,a,b' into '-Xcompiler -Wl,a,b', and nvcc splits an -Xcompiler
# rpath    argument on its commas — so the host compiler receives '-Wl', '-soname' and the
#           name as three separate options and rejects the first two. The -Xlinker form
#           passes each word through untouched. Note that '-Xcompiler=-Wl,-soname,NAME' is
#           accepted SILENTLY and records no SONAME at all: a green build whose artifact
#           cannot be linked against by name. That is the worse failure and the reason these
#           are spelled out here rather than left to each description to get right.
#
# '$$ORIGIN' survives to the shell as a literal because make expands a recipe once: the '$$'
# becomes '$' in this value, and the single quotes then stop the shell expanding '$ORIGIN'
# to nothing. mk/derive.mk:375 and components/gpu-coprocessor.conf document the same trap.
ifeq ($(TARGET_GPU_VENDOR),nvidia)
  TARGET_GPU_STD_FLAG     := -std=c++$(TARGET_CXX_STANDARD)
  TARGET_GPU_SONAME_FLAG   = -Xlinker -soname -Xlinker $(1)
  TARGET_GPU_ORIGIN_FLAG  := -Xlinker -rpath -Xlinker '$$ORIGIN'
else
  TARGET_GPU_STD_FLAG     := $(TARGET_STD_FLAG)
  TARGET_GPU_SONAME_FLAG   = $(call TARGET_SONAME_FLAG,$(1))
  TARGET_GPU_ORIGIN_FLAG  := -Wl$(COMMA)-rpath$(COMMA)'$$ORIGIN'
endif

# ── 5. Sysroot-derived include and library paths ─────────────────────────────
# Deferred (=, not :=) so the shell only runs when a recipe actually needs them.
# An eager := would probe a sysroot that may not exist yet, printing spurious
# errors during `make list-targets`.
SYSROOT_CXX_FLAGS  = $(shell $(TOOLS_DIR)/sysroot-inspect.sh cxxflags $(SYSROOT_DIR) $(TARGET_TRIPLE) $(TARGET_STDLIB) $(TARGET_SYSROOT_GCC_VERSION))
SYSROOT_LINK_FLAGS = $(shell $(TOOLS_DIR)/sysroot-inspect.sh ldflags  $(SYSROOT_DIR) $(TARGET_TRIPLE) $(TARGET_STDLIB) $(TARGET_SYSROOT_GCC_VERSION))

# ── 6. Generated cmake toolchain file ────────────────────────────────────────
# Generated, never hand-written. The old tree hand-maintained one .cmake file per
# board that restated the same facts as the Make flags; the two representations
# were kept aligned by a comment. Generation makes divergence impossible.
CMAKE_TOOLCHAIN_FILE := $(TARGET_BUILD_DIR)/toolchain.cmake

# ── 7. Job control ───────────────────────────────────────────────────────────
# nproc is Linux, sysctl is macOS/BSD; falling back to 4 keeps this working on a
# host with neither rather than expanding to empty and passing a bare `-j`, which
# means "unlimited" and will OOM a machine when linking LLVM.
JOBS      ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
LINK_JOBS ?= 1
BUILD_TYPE ?= Release

endif # DERIVE_MK_INCLUDED
