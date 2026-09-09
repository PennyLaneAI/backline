# ─────────────────────────────────────────────────────────────────────────────
# mk/rules.mk — the generic build recipes.
#
# There is ONE recipe per COMPONENT_KIND, and it works for every target. That is
# the whole payoff of the redesign: the recipe count is a function of how many
# *kinds of thing* exist (three: executable, shared library, cmake project), not
# of how many components times how many boards.
#
# For comparison, the design this replaces had 15 hand-written recipes across 9
# Makefiles to build 8 artifacts for 3 targets — and the coverage was ragged
# (some artifacts had recipes for only one board), which was invisible until you
# tried the missing combination.
#
# Included once per component build, with the component's variables already set.
# ─────────────────────────────────────────────────────────────────────────────

ifndef COMPONENT_NAME
  $(error mk/rules.mk needs a component. Invoke via the top-level Makefile.)
endif

COMPONENT_KIND       ?= shared-library
COMPONENT_OUTPUT     ?= $(COMPONENT_NAME)
COMPONENT_SONAME     ?= $(COMPONENT_OUTPUT)
COMPONENT_OPTIONAL   ?= no
COMPONENT_STATIC_CXX ?= no
COMPONENT_REQUIRES_NATIVE ?= no
COMPONENT_REQUIRES_GPU_ARCH ?= no

OUT_DIR  := $(TARGET_BUILD_DIR)/components/$(COMPONENT_NAME)
ARTIFACT := $(OUT_DIR)/$(COMPONENT_OUTPUT)

# ── Source-root validation ───────────────────────────────────────────────────
# Checked before anything else so that an unset root is reported by NAME, together
# with which component wanted it. The old tree's equivalent was a hand-copied
# ifeq/$(error) in each Makefile, which meant the message quality varied and some
# components only checked for emptiness while others also validated the tree.
$(foreach root,$(COMPONENT_SOURCE_ROOTS), \
  $(if $(strip $($(root))),, \
    $(error Component '$(COMPONENT_NAME)' needs the source root '$(root)', which is not set.$(NEWLINE)\
      Pass it on the command line:  make build TARGET=$(TARGET_NAME) $(root)=/path/to/tree$(NEWLINE)\
      Or set it once in config.mk (see config.mk.example).)))

# Also verify the roots point at something real. A typo'd path otherwise surfaces
# as a compiler error about a missing source file, which reads like the build
# system is broken rather than like the path is wrong.
$(foreach root,$(COMPONENT_SOURCE_ROOTS), \
  $(if $(wildcard $($(root))),, \
    $(error Component '$(COMPONENT_NAME)': source root $(root)=$($(root)) does not exist.)))

# ── normalise each root to an absolute, tilde-expanded path ──────────────────
#
# `CATALYST=~/catalyst` is what the documentation itself tells people to type, and it used
# to produce a build that failed with
#     fatal error: 'RuntimeCAPI.h' file not found
# naming a header rather than the path that was wrong. The cause is a disagreement between
# two consumers of one value: Make's $(wildcard) DOES expand a leading '~', so the check
# above passed, while the compiler does NOT, so `-I~/catalyst/runtime/include` reached it
# as a literal directory named '~'. A check that accepts what the compiler rejects is worse
# than no check, because it moves the error away from its cause.
#
# $(wildcard) is what does the expansion — $(abspath) alone leaves '~' untouched — and
# $(abspath) then makes a relative root absolute, which a component's sources need anyway
# since each is compiled from a different directory.
# `override` is required, not decorative: a source root arrives on the command line
# (make build ... CATALYST=~/catalyst), and a command-line variable outranks every ordinary
# assignment in a makefile. Without it the normalisation is silently discarded and the
# literal '~' reaches the compiler exactly as before.
$(foreach root,$(COMPONENT_SOURCE_ROOTS), \
  $(eval override $(root) := $(abspath $(firstword $(wildcard $($(root)))))))

# ── Native-only enforcement ──────────────────────────────────────────────────
# Some code (HIP/CUDA device kernels) can only be compiled by a vendor compiler
# that is not a cross-compiler. Detect the mismatch here and explain it, rather
# than letting hipcc receive --target=aarch64-linux-gnu and emit a wall of errors
# whose cause is one line in a config file.
#
# Compare CANONICAL triples, not the spellings. A host reporting x86_64-pc-linux-gnu
# and a description saying x86_64-linux-gnu are the same machine; comparing the raw
# strings rejected a native component on the one machine that could build it. Both
# sides go through detect-host.sh normalize-triple, which asks the compiler for its
# canonical form. If normalisation is unavailable (no compiler at all) fall back to
# the raw strings rather than comparing two empty values, which would silently make
# every mismatch look native.
ifeq ($(COMPONENT_REQUIRES_NATIVE),yes)
  HOST_TRIPLE := $(shell $(TOOLS_DIR)/detect-host.sh triple)
  _HOST_TRIPLE_CANON   := $(shell $(TOOLS_DIR)/detect-host.sh normalize-triple $(HOST_TRIPLE))
  _TARGET_TRIPLE_CANON := $(shell $(TOOLS_DIR)/detect-host.sh normalize-triple $(TARGET_TRIPLE))
  ifeq ($(strip $(_HOST_TRIPLE_CANON)),)
    _HOST_TRIPLE_CANON   := $(HOST_TRIPLE)
    _TARGET_TRIPLE_CANON := $(TARGET_TRIPLE)
  endif
  ifeq ($(strip $(_TARGET_TRIPLE_CANON)),)
    _HOST_TRIPLE_CANON   := $(HOST_TRIPLE)
    _TARGET_TRIPLE_CANON := $(TARGET_TRIPLE)
  endif
  ifneq ($(_TARGET_TRIPLE_CANON),$(_HOST_TRIPLE_CANON))
    $(error Component '$(COMPONENT_NAME)' is marked COMPONENT_REQUIRES_NATIVE=yes, \
      but target '$(TARGET_NAME)' is $(TARGET_TRIPLE) ($(_TARGET_TRIPLE_CANON)) while this \
      host is $(HOST_TRIPLE) ($(_HOST_TRIPLE_CANON)).$(NEWLINE)\
      This component uses a vendor compiler that cannot cross-compile. Build it on \
      a machine of the target architecture, or exclude it from this target's bundle.)
  endif
endif

# ── GPU architecture ─────────────────────────────────────────────────────────
# A component compiling device code must be told which GPU to emit for. That is a
# property of the machine being built FOR, so it lives in the target description;
# it is never inferred from the machine being built ON, which may hold a different
# card or none at all. Refusing here beats letting the vendor compiler receive
# '--offload-arch=' with nothing after it.
ifeq ($(COMPONENT_REQUIRES_GPU_ARCH),yes)
  ifeq ($(strip $(TARGET_GPU_ARCH)),)
    $(error Component '$(COMPONENT_NAME)' is marked COMPONENT_REQUIRES_GPU_ARCH=yes, but$(NEWLINE)\
      target '$(TARGET_NAME)' names no TARGET_GPU_ARCH.$(NEWLINE)\
      Set it in targets/$(TARGET_NAME).conf, which 'make probe' fills in from the machine$(NEWLINE)\
      itself, or pass GPU_ARCH=<arch> on this command line for a one-off build.$(NEWLINE)\
      It is not detected from this host on purpose: the card you build on need not be the$(NEWLINE)\
      card the artifact runs on)
  endif
  # The vendor, and so every flag spelling below, is derived from how the architecture is
  # written: 'gfx<n>' is AMD, 'sm_<n>' is NVIDIA (mk/derive.mk). A name matching neither
  # leaves the derivation empty, and an empty architecture flag compiles for the driver's
  # own default card instead — device code that loads and then produces nothing on the
  # card actually installed. Refuse by name here instead.
  ifeq ($(strip $(TARGET_GPU_ARCH_FLAG)),)
    $(error Target '$(TARGET_NAME)' names TARGET_GPU_ARCH=$(TARGET_GPU_ARCH), which matches$(NEWLINE)\
      no known vendor spelling, so component '$(COMPONENT_NAME)' cannot be told which card$(NEWLINE)\
      to emit device code for.$(NEWLINE)\
      Expected 'gfx<n>' for an AMD card (e.g. gfx90a) or 'sm_<n>' for an NVIDIA one$(NEWLINE)\
      (e.g. sm_80). 'make probe' writes the right spelling for either; `rocminfo` and$(NEWLINE)\
      `nvidia-smi --query-gpu=compute_cap --format=csv` are where it reads them from.)
  endif
endif

# ── Flag assembly ────────────────────────────────────────────────────────────
# Precedence, lowest to highest:
#   1. mk/derive.mk        (the target's machine properties)
#   2. the sysroot's own include/lib paths (discovered)
#   3. the component's own flags
# Component last means a component CAN override a target default when it must,
# and the ordering is stated here in one place rather than being an accident of
# how each recipe happened to concatenate its variables.

_INCLUDE_FLAGS := $(addprefix -I,$(COMPONENT_INCLUDES))
_LIB_FLAGS     := $(addprefix -l,$(COMPONENT_LIBS))

ifeq ($(COMPONENT_STATIC_CXX),yes)
  # All three of these are GCC/GNU-ld spellings with no Mach-O equivalent, and Darwin
  # ships no static C++ runtime to link in the first place. Refused by name here rather
  # than passed through, because the alternative is three separate driver errors
  # ("argument unused", "invalid library name", "unknown argument '--exclude-libs'")
  # that name the flags and not the one description field that asked for them.
  ifeq ($(TARGET_BINFMT),macho)
    $(error Component '$(COMPONENT_NAME)' sets COMPONENT_STATIC_CXX=yes, which cannot be \
      honoured for target '$(TARGET_NAME)' ($(TARGET_TRIPLE)).$(NEWLINE)\
      That option links the C++ runtime statically using -static-libstdc++ and \
      -Wl,--exclude-libs — both GNU-ld only — and Darwin provides no static libc++ to \
      link. Set COMPONENT_STATIC_CXX=no, or exclude this component from this target.)
  endif
  # --exclude-libs,ALL prevents the statically-linked libstdc++ symbols from being
  # re-exported. Without it the plugin exports its private C++ runtime, and a
  # process that dlopens two such plugins gets one's allocator paired with the
  # other's deallocator. See components/SCHEMA.md for why this is a considered
  # choice and not a free win.
  _STATIC_CXX_FLAGS := -static-libstdc++ -static-libgcc -Wl,--exclude-libs,ALL
else
  _STATIC_CXX_FLAGS :=
endif

# Resolve component dependencies to real paths. This is what replaces the old
# hardcoded '../<dependency>/build/<target>/lib<dependency>.so'
# — the path is computed from the dependency's NAME and the CURRENT target, so it
# is right for every target automatically.
_DEP_DIRS  := $(foreach d,$(COMPONENT_DEPENDS),$(TARGET_BUILD_DIR)/components/$d)
_DEP_LFLAGS := $(foreach d,$(COMPONENT_DEPENDS),-L$(TARGET_BUILD_DIR)/components/$d)
# Strip the lib prefix and .so suffix to form -l names, since that is the only
# form the linker accepts.
_DEP_LIBS  := $(foreach d,$(COMPONENT_DEPENDS),\
                $(patsubst lib%,-l%,$(basename $(notdir $(shell \
                  $(TOOLS_DIR)/component-output.sh $(ROOT_DIR) $d)))))

CXX_INVOKE := $(if $(strip $(COMPONENT_CXX_OVERRIDE)),$(COMPONENT_CXX_OVERRIDE),$(TARGET_CXX))
CC_INVOKE  := $(if $(strip $(COMPONENT_CC_OVERRIDE)),$(COMPONENT_CC_OVERRIDE),$(TARGET_CC))

# A component compiling device code is built by the VENDOR's driver, which need not speak the
# same flag dialect as the rest of this tree. Gated on the component rather than the target on
# purpose: only the component that actually invokes the vendor compiler gets the vendor
# spellings, so an ordinary C++ component on the same machine is unaffected.
_USES_GPU_DIALECT := $(filter yes,$(COMPONENT_REQUIRES_GPU_ARCH))

# A native component using a vendor compiler must not be handed cross flags: the triple flag
# and the sysroot are meaningless (and often rejected) there. The C++ standard stays, because
# it describes the source — C++20 code must still compile as C++20 under a vendor compiler,
# though a vendor driver may insist on its own spelling of it (mk/derive.mk).
ifeq ($(COMPONENT_REQUIRES_NATIVE),yes)
  _INHERITED_CXX_FLAGS := $(if $(_USES_GPU_DIALECT),$(TARGET_GPU_STD_FLAG),$(TARGET_STD_FLAG))
  # The sysroot describes the machine being built FOR. A native component is built for THIS
  # machine, so the sysroot's include and library paths are not merely redundant but wrong,
  # and a vendor driver rejects their spellings outright: nvcc refuses the '-B<dir>' the cxx
  # flags carry, and comma-splits the '-Wl,-rpath-link' the link flags carry.
  #
  # Withholding these completes what withholding the cross flags above already intends — the
  # sentence above has always said "and the sysroot", and these two were simply missed. They
  # went unnoticed because clang accepts both harmlessly, so the one native component in the
  # tree built anyway; nvcc is the first driver to refuse them.
  _INHERITED_SYSROOT_CXX  :=
  _INHERITED_SYSROOT_LINK :=
else
  _INHERITED_CXX_FLAGS    := $(TARGET_CXX_FLAGS)
  _INHERITED_SYSROOT_CXX  := $(SYSROOT_CXX_FLAGS)
  _INHERITED_SYSROOT_LINK := $(SYSROOT_LINK_FLAGS)
endif

# The vendor driver may also need its own environment: hipcc dispatches to ROCm's clang++ or
# to nvcc according to HIP_PLATFORM, and with it unset on a CUDA host it picks clang++, which
# then rejects '-gencode' and '-Xcompiler'. Prefixed onto the recipe rather than exported, so
# it is visible in the echoed command line and scoped to the one component that needs it.
_GPU_RECIPE_ENV := $(if $(_USES_GPU_DIALECT),$(if $(filter nvidia,$(TARGET_GPU_VENDOR)),HIP_PLATFORM=nvidia,),)

# How this component's shared library names itself, in the dialect its compiler speaks.
_SONAME_FLAG = $(if $(_USES_GPU_DIALECT),$(call TARGET_GPU_SONAME_FLAG,$(1)),$(call TARGET_SONAME_FLAG,$(1)))

# -fPIC stays here because it is a property of the KIND of thing being built, not of the
# machine. The optimisation level does not: it moved to TARGET_OPT_FLAGS in mk/derive.mk,
# where flags belong and where `make show-target` can print it. As a literal here it was
# appended after the target's own flags and silently beat TARGET_CXXFLAGS=-O3.
ALL_CXXFLAGS := $(_INHERITED_CXX_FLAGS) $(_INHERITED_SYSROOT_CXX) -fPIC \
                $(_INCLUDE_FLAGS) $(COMPONENT_CXXFLAGS)

# COMPONENT_CFLAGS is documented, so it must actually reach the compiler. Sources are
# compiled in one invocation of the C++ driver (which handles .c files too), so C-only
# flags are appended here rather than needing a separate C recipe. A component that is
# pure C and needs C-only flags should use COMPONENT_CFLAGS; mixing genuinely
# C-incompatible flags into a C++ TU is the user's decision to make explicitly.
ifneq ($(strip $(COMPONENT_CFLAGS)),)
  ALL_CXXFLAGS += $(COMPONENT_CFLAGS)
endif

ALL_LDFLAGS  := $(if $(filter yes,$(COMPONENT_REQUIRES_NATIVE)),,$(TARGET_LINK_FLAGS)) \
                $(_INHERITED_SYSROOT_LINK) $(_STATIC_CXX_FLAGS) \
                $(_DEP_LFLAGS) $(COMPONENT_LDFLAGS)

# ── Recipes ──────────────────────────────────────────────────────────────────

.PHONY: component component-clean component-info

# '@:' is a deliberate do-nothing recipe, not a leftover. Without any recipe, make
# prints "Nothing to be done for 'component'" every time an artifact is already up to
# date — a phrase that reads like a misconfiguration when it actually means success,
# and which repeated once per component drowned the real errors in a whole-tree build.
# The recipe stays silent instead; the top-level 'build' summary reports what was made.
component: $(ARTIFACT)
	@:

$(OUT_DIR):
	@mkdir -p $@

# Dependencies are built by the top-level Makefile before this runs; here we only
# need the ordering within a single component's link.
_DEP_ARTIFACTS := $(foreach d,$(COMPONENT_DEPENDS),\
                    $(TARGET_BUILD_DIR)/components/$d/$(shell \
                      $(TOOLS_DIR)/component-output.sh $(ROOT_DIR) $d))

# Rebuild triggers common to every kind.
#
# The DESCRIPTIONS are prerequisites, not just the sources. Without this, editing
# TARGET_DYNAMIC_LINKER (or the C++ standard, or a define) and rebuilding reports
# "Nothing to be done" and leaves a stale artifact that `make verify` then fails on —
# so the build and the verifier disagree about a file make believes is current.
# Re-fetching a sysroot must invalidate everything built against the previous one.
# get-sysroot.sh writes this marker at the end of every successful fetch, so its mtime is
# precisely "when these headers and libraries appeared".
#
# Without it, a sysroot repaired after a failed build leaves artifacts — and a generated
# cmake toolchain file — produced against the broken tree, and the next build reports
# success while using them. Observed: a rootfs fetched without -dev packages produced a
# toolchain.cmake with no -isystem for the C++ headers, because none existed yet; after
# installing them and re-fetching, the direct path recovered (its flags are recomputed
# every run) while the cmake path kept failing on 'cstdio' file not found from the stale
# generated file.
#
# $(wildcard) so an absent marker — SYSROOT_PROVIDER=none, or a symlinked sysroot, where
# get-sysroot.sh deliberately writes none — drops out of the list rather than becoming a
# prerequisite with no rule to build it.
_SYSROOT_STAMP := $(wildcard $(SYSROOT_DIR)/.crossbuild-sysroot-ready)

_REBUILD_ON := $(TARGET_CONF_FILE) $(COMPONENT_CONF_FILE) $(_SYSROOT_STAMP)

# ── pre-flight checks for the direct compile paths ───────────────────────────
#
# The cmake path has long checked `command -v cmake` and explained itself. These give the
# direct paths the same courtesy, for the two things that otherwise fail in a way that names
# neither the component nor the cause.
#
# A missing vendor compiler used to surface as:
#     make[1]: hipcc: No such file or directory
#     make[1]: *** [.../libgpu_coprocessor.so] Error 127
# — an errno, with no mention of which component wanted it or where that name came from.
_CHECK_COMPILER = @command -v $(CXX_INVOKE) >/dev/null 2>&1 || { \
	  echo "ERROR: component '$(COMPONENT_NAME)' needs the compiler '$(CXX_INVOKE)', which is not executable or not on PATH."; \
	  echo "       That name comes from $(if $(strip $(COMPONENT_CXX_OVERRIDE)),COMPONENT_CXX_OVERRIDE in components/$(COMPONENT_NAME).conf,TOOLCHAIN_KIND=$(TOOLCHAIN_KIND) resolved against TOOLCHAIN_ROOT=$(TOOLCHAIN_ROOT))."; \
	  exit 1; }

# And a library the target lacks used to surface as a compiler error inside a vendor header,
# repeated once per source file — naming neither the library nor the sysroot:
#     Context.hpp:19:10: fatal error: 'infiniband/verbs.h' file not found
# The layout question ("can -lfoo be satisfied here?") belongs to sysroot-inspect.sh, which
# owns every other question about what a sysroot contains.
_CHECK_LIBS = @for l in $(COMPONENT_LIBS); do \
	  msg=$$($(TOOLS_DIR)/sysroot-inspect.sh haslib "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)" "$$l" 2>&1) || { \
	    echo "ERROR: component '$(COMPONENT_NAME)' declares COMPONENT_LIBS=$$l, which this sysroot cannot link."; \
	    printf '       %s\n' "$$msg" | sed 's/^       /       /'; \
	    exit 1; }; \
	done

# Record which compiler actually produced this artifact, beside the artifact.
#
# `make bundle` copies; it never builds. So the bundle receipt used to report the compiler
# resolved at BUNDLE time, which is a different question and can be a different answer — and
# the documented macOS fix for readelf (`export PATH="$(brew --prefix llvm)/bin:$PATH"`)
# swaps Apple clang for Homebrew clang silently, which is exactly the swap the receipt exists
# to make visible. Following the documented order therefore produced the failure the receipt
# was supposed to catch. Stamping at build time is the only place that knows the truth.
# Record the linker BINARY, not just its name. -fuse-ld=lld makes clang search PATH for
# `ld.lld`, and which one wins is PATH order — a fully-built LLVM elsewhere (e.g. a Catalyst
# checkout) can shadow the one the docs point at. The compiler is stamped per artifact for
# exactly this reason; the linker was named but not resolved, so a silent linker swap left no
# trace. Map the TARGET_LINKER name to the binary clang will invoke and record where it
# resolved from. ('default' means no -fuse-ld, so the compiler picks — nothing to resolve.)
_LINKER_BIN := $(if $(filter lld,$(TARGET_LINKER)),ld.lld,$(if $(filter bfd,$(TARGET_LINKER)),ld.bfd,$(if $(filter gold,$(TARGET_LINKER)),ld.gold,$(if $(filter mold,$(TARGET_LINKER)),mold,))))
_STAMP_COMPILER = @{ \
	  printf 'compiler=%s\n' "$$(command -v $(CXX_INVOKE) 2>/dev/null || echo $(CXX_INVOKE))"; \
	  printf 'version=%s\n' "$$($(CXX_INVOKE) --version 2>/dev/null | head -1)"; \
	  printf 'linker=%s\n' "$(TARGET_LINKER)"; \
	  printf 'linker_bin=%s\n' "$(if $(_LINKER_BIN),$$(command -v $(_LINKER_BIN) 2>/dev/null || echo '$(_LINKER_BIN) (not found on PATH)'),compiler default)"; \
	} > "$(OUT_DIR)/.crossbuild-built-with" 2>/dev/null || true

ifeq ($(COMPONENT_KIND),shared-library)

$(ARTIFACT): $(COMPONENT_SOURCES) $(_DEP_ARTIFACTS) $(_REBUILD_ON) | $(OUT_DIR)
	@$(TOOLS_DIR)/sysroot-inspect.sh probe "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)"
	$(_CHECK_COMPILER)
	$(_CHECK_LIBS)
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] compiling shared library"
	$(_GPU_RECIPE_ENV) $(CXX_INVOKE) -shared $(ALL_CXXFLAGS) \
	    $(call _SONAME_FLAG,$(COMPONENT_SONAME)) \
	    $(COMPONENT_SOURCES) \
	    $(ALL_LDFLAGS) $(_DEP_LIBS) $(_LIB_FLAGS) \
	    -o $@
	$(_STAMP_COMPILER)
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] -> $@"

else ifeq ($(COMPONENT_KIND),executable)

$(ARTIFACT): $(COMPONENT_SOURCES) $(_DEP_ARTIFACTS) $(_REBUILD_ON) | $(OUT_DIR)
	@$(TOOLS_DIR)/sysroot-inspect.sh probe "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)"
	$(_CHECK_COMPILER)
	$(_CHECK_LIBS)
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] compiling executable"
	$(_GPU_RECIPE_ENV) $(CXX_INVOKE) $(ALL_CXXFLAGS) \
	    $(COMPONENT_SOURCES) \
	    $(ALL_LDFLAGS) $(_DEP_LIBS) $(_LIB_FLAGS) \
	    -o $@
	$(_STAMP_COMPILER)
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] -> $@"

else ifeq ($(COMPONENT_KIND),cmake-project)

# The cmake toolchain file is GENERATED from the same variables the direct paths
# above use. This is the structural fix for the old tree's duplicated CPU flag and
# dynamic-linker path, which a per-board design states twice — once for the direct
# compiler path and once in that board's cmake toolchain file
# under a "KEEP IN SYNC" comment.
CMAKE_BUILD_DIR := $(OUT_DIR)/cmake-build

# No order-only prerequisite on $(TARGET_BUILD_DIR): nothing declares a rule to
# create it, so on a clean tree cmake components failed with
#   No rule to make target '.../build/<target>'
# The recipe's own mkdir -p is sufficient and has no such failure mode.
# Depends on the sysroot stamp as well as the description: the generator bakes in the
# DISCOVERED sysroot paths (-isystem for the C++ headers, -B for the GCC support dir), so
# the file is only as correct as the sysroot that existed when it ran.
$(CMAKE_TOOLCHAIN_FILE): $(TARGET_CONF_FILE) $(_SYSROOT_STAMP)
	@mkdir -p $(dir $@)
	@$(TOOLS_DIR)/gen-cmake-toolchain.sh > $@

# .PHONY would rebuild every time; instead depend on the upstream CMakeLists and on
# every source under the project dir, so editing code actually triggers a rebuild.
# Previously the artifact depended only on the toolchain file, which meant editing
# main.cpp and rebuilding was a silent no-op — the worst possible behaviour for a
# build system, since you then test the old binary believing it is the new one.
_CMAKE_WATCH := $(wildcard $(COMPONENT_CMAKE_SOURCE_DIR)/CMakeLists.txt) \
                $(wildcard $(COMPONENT_CMAKE_SOURCE_DIR)/*.cpp) \
                $(wildcard $(COMPONENT_CMAKE_SOURCE_DIR)/*.c) \
                $(wildcard $(COMPONENT_CMAKE_SOURCE_DIR)/*.h) \
                $(wildcard $(COMPONENT_CMAKE_SOURCE_DIR)/*.hpp) \
                $(wildcard $(COMPONENT_CMAKE_SOURCE_DIR)/src/*)

$(ARTIFACT): $(CMAKE_TOOLCHAIN_FILE) $(_DEP_ARTIFACTS) $(_REBUILD_ON) $(_CMAKE_WATCH) | $(OUT_DIR)
	@$(TOOLS_DIR)/sysroot-inspect.sh probe "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)"
	@command -v cmake >/dev/null || { echo "ERROR: cmake is required for COMPONENT_KIND=cmake-project but was not found in PATH."; exit 1; }
	@# A newer toolchain file is not enough on its own. The generator emits flags as
	@# CMAKE_<LANG>_FLAGS_INIT, and the _INIT variants seed the cache ONLY on the first
	@# configure — every later configure reads the cached value and ignores them. So a
	@# corrected toolchain file applied to an existing build dir changes nothing, and the
	@# build keeps using flags derived from a sysroot that has since been repaired.
	@# Dropping the build dir forces a genuine first configure.
	@if [ -f $(CMAKE_BUILD_DIR)/CMakeCache.txt ] \
	   && [ $(CMAKE_TOOLCHAIN_FILE) -nt $(CMAKE_BUILD_DIR)/CMakeCache.txt ]; then \
	  echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] toolchain file is newer than the cmake cache -> reconfiguring from scratch"; \
	  rm -rf $(CMAKE_BUILD_DIR); \
	fi
	@mkdir -p $(CMAKE_BUILD_DIR)
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] configuring cmake"
	cmake -S $(COMPONENT_CMAKE_SOURCE_DIR) -B $(CMAKE_BUILD_DIR) \
	    $(if $(shell command -v ninja 2>/dev/null),-G Ninja,) \
	    -DCMAKE_TOOLCHAIN_FILE=$(CMAKE_TOOLCHAIN_FILE) \
	    -DCMAKE_BUILD_TYPE=$(BUILD_TYPE) \
	    $(COMPONENT_CMAKE_ARGS)
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] building"
	cmake --build $(CMAKE_BUILD_DIR) -j $(JOBS) \
	    $(if $(strip $(COMPONENT_CMAKE_TARGET)),--target $(COMPONENT_CMAKE_TARGET),)
	@# Upstream cmake projects put artifacts wherever they like, so find it rather
	@# than assuming a layout. Assuming is how you get a "file not found" for a
	@# file that was built successfully two directories away.
	@found=$$(find $(CMAKE_BUILD_DIR) -name '$(COMPONENT_OUTPUT)' -type f -print -quit); \
	 if [ -z "$$found" ]; then \
	   echo "ERROR: cmake build finished but '$(COMPONENT_OUTPUT)' was not found under $(CMAKE_BUILD_DIR)."; \
	   echo "       Check COMPONENT_OUTPUT matches what this project actually produces."; \
	   exit 1; \
	 fi; \
	 cp -f "$$found" $@
	@echo "[$(TARGET_NAME)/$(COMPONENT_NAME)] -> $@"

else
  $(error Component '$(COMPONENT_NAME)': COMPONENT_KIND='$(COMPONENT_KIND)' is not \
    recognised. Use executable, shared-library, or cmake-project.)
endif

component-clean:
	rm -rf $(OUT_DIR)

component-info:
	@echo "component : $(COMPONENT_NAME)  ($(COMPONENT_KIND))"
	@echo "target    : $(TARGET_NAME)  [$(TARGET_TRIPLE)]"
	@echo "artifact  : $(ARTIFACT)"
	@echo "sources   : $(COMPONENT_SOURCES)"
	@echo "depends   : $(if $(strip $(COMPONENT_DEPENDS)),$(COMPONENT_DEPENDS),none)"
	@echo
	@echo "compile   : $(_GPU_RECIPE_ENV) $(CXX_INVOKE) $(ALL_CXXFLAGS)"
	@echo
	@# The name the artifact records for itself, and the only part of the link that is not in
	@# ALL_LDFLAGS — the recipe passes it separately. Shown because its spelling is
	@# vendor-dependent and one wrong spelling is accepted in silence: nvcc takes
	@# '-Xcompiler=-Wl,-soname,NAME' without complaint and records no SONAME at all, so the
	@# only way to see which form a component got, short of linking it, is here.
	@echo "soname    : $(if $(filter shared-library,$(COMPONENT_KIND)),$(call _SONAME_FLAG,$(COMPONENT_SONAME)),<not a shared library>)"
	@echo
	@# The link flags contain -Wl,-rpath,'$$ORIGIN', quoted for the compiler. A plain echo
	@# runs that through the shell, which — the surrounding double-quotes not protecting a
	@# literal single-quoted token — expands $$ORIGIN to nothing and prints -Wl,-rpath,''.
	@# That sent a reader chasing a missing-library failure to a command that told them the
	@# rpath was blank when the build embeds $$ORIGIN. Strip the inner quotes for display, as
	@# show-target does; the build output shows exactly what the compiler receives.
	@printf 'link      : %s\n' '$(subst ','"'"',$(ALL_LDFLAGS) $(_DEP_LIBS) $(_LIB_FLAGS))'
