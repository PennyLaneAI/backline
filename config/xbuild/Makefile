# ─────────────────────────────────────────────────────────────────────────────
# crossbuild — a target-agnostic cross-compilation build system.
#
# THE ONE IDEA
# ------------
# Three kinds of plain data file describe everything:
#
#     targets/<name>.conf      a machine you want binaries for
#     components/<name>.conf   a thing you want built
#     bundles/<name>.conf      a set of things you want deployed together
#
# Nothing else in this tree knows about any specific machine. Adding a board means
# writing one file in targets/ — no new Makefile, no new cmake file, no new recipe,
# and no edits to anything under mk/ or tools/. If you find yourself editing the
# machinery to add hardware, that is a bug.
#
# START HERE
#     make help                        what you can do
#     make list-targets                what machines are described
#     make doctor                      is this build host able to cross-compile?
#     make quickstart                  a guided first build, explained as it goes
#
# TYPICAL FLOW
#     make list-targets                              # is it described already?
#     make probe TARGET=my-board SSH=user@my-board   # only if it is NOT — writes the description
#     make sysroot TARGET=my-board                   # fetch its libraries
#     make build   TARGET=my-board COMPONENT=<name> CATALYST=~/src
#     make bundle  TARGET=my-board BUNDLE=<name>     # `make list-bundles` marks the real ones
#
# Full documentation is in docs/, starting with docs/01-concepts.md.
#
# Building a SPECIFIC project's deliverables rather than learning the system? Its own
# instructions name the target and the components; this file cannot, because nothing here
# knows which machine you meant. In this checkout that is ../../INSTALL.md.
# ─────────────────────────────────────────────────────────────────────────────

ROOT_DIR   := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BUILD_DIR  := $(ROOT_DIR)/build
TOOLS_DIR  := $(ROOT_DIR)/tools
GEN_DIR    := $(BUILD_DIR)/generated

# A newline, for multi-line $(error) messages. Make has no escape for one.
define NEWLINE


endef

# Optional local settings, so nobody has to retype source-root paths on every
# command line. Not tracked; see config.mk.example.
-include $(ROOT_DIR)/config.mk

# Discover what exists by looking, not by maintaining a list. A list would be a
# second place to update and therefore a second place to forget.
ALL_TARGETS    := $(sort $(notdir $(basename $(wildcard $(ROOT_DIR)/targets/*.conf))))
ALL_COMPONENTS := $(sort $(notdir $(basename $(wildcard $(ROOT_DIR)/components/*.conf))))
ALL_BUNDLES    := $(sort $(notdir $(basename $(wildcard $(ROOT_DIR)/bundles/*.conf))))

# The ones that are somebody's actual deliverable, as opposed to illustrations and test
# fixtures. Every list of bundles used to be alphabetical and undifferentiated, so a reader
# who had just built successfully was offered seven names with the only correct one last and
# nothing marking it. `example-` and `test-` are the naming convention this tree already
# uses for the two kinds of not-real; this makes the convention do some work.
REAL_BUNDLES   := $(filter-out example-% test-%,$(ALL_BUNDLES))
DEMO_BUNDLES   := $(filter example-% test-%,$(ALL_BUNDLES))

# Same split for machines. Two targets named for the same board — a real one probed off the
# hardware and an `example-` illustration of how such a board is described — confused every
# reader who met them side by side in an undifferentiated list, especially since the example
# could carry the more convincing description. The `example-`/`test-` convention already marks
# which is which; surfacing it in `make list-targets` is what makes the shortcut safe.
REAL_TARGETS   := $(filter-out example-% test-%,$(ALL_TARGETS))
DEMO_TARGETS   := $(filter example-% test-%,$(ALL_TARGETS))

# And for components, so all three listings group the deliverables apart from the
# illustrations identically. Without this, list-components was the one discovery command that
# could not tell you hwhs-*/rt-* are the real things and example-*/test-* are not.
REAL_COMPONENTS := $(filter-out example-% test-%,$(ALL_COMPONENTS))
DEMO_COMPONENTS := $(filter example-% test-%,$(ALL_COMPONENTS))

.DEFAULT_GOAL := help

# ── Goals that need no target ────────────────────────────────────────────────
NO_TARGET_GOALS := help list-targets list-components list-bundles doctor \
                   quickstart validate clean clean-all check test \
                   pseudo-remote pseudo-remote-down

# ── Goals that need TARGET= but must NOT require an existing description ─────
# They are the two goals that CREATE one. Requiring the file they are about to write made
# the documented first step of the whole workflow impossible:
#     $ make probe TARGET=demo-box SSH=root@localhost
#     *** No description for target 'demo-box' ... Or from a live machine: make probe ...
# — advice to run the command that had just been refused.
TARGET_CREATING_GOALS := probe new-target

.PHONY: $(NO_TARGET_GOALS) sysroot sysroot-clean sysroot-info catalyst-llvm build verify \
        bundle deploy probe show-target show-component clean-target new-target

# ─────────────────────────────────────────────────────────────────────────────
# Informational goals
# ─────────────────────────────────────────────────────────────────────────────

help:
	@echo "crossbuild — build binaries for a machine that is not this one."
	@echo ""
	@echo "FIRST TIME HERE"
	@echo "  make quickstart              a guided first build, explained as it goes"
	@echo "  make doctor                  can this host cross-compile? what is missing?"
	@echo ""
	@echo "DISCOVER"
	@echo "  make list-targets            machines that have a description"
	@echo "  make list-components         things that can be built"
	@echo "  make list-bundles            deployable sets (deliverables vs examples)"
	@echo "  make show-target TARGET=t    fully-resolved settings + exact compiler flags"
	@echo "  make show-component TARGET=t COMPONENT=c   one component's exact command line"
	@echo "  make validate                check every description for errors"
	@echo "  make check                   validate, plus cross-check bundle->component refs"
	@echo "  make test                    run the build system's own test suite (VERBOSE=1 for output)"
	@echo ""
	@echo "DESCRIBE A NEW MACHINE"
	@echo "  make probe TARGET=t SSH=user@host   read the target's ABI over ssh and"
	@echo "                                      write targets/t.conf for you"
	@echo "                                      (on an existing file: updates the probed"
	@echo "                                      facts only. FRESH=1 regenerates it)"
	@echo "  make new-target TARGET=t            start from a commented template"
	@echo "  make pseudo-remote                  start an aarch64 machine in Docker to practise"
	@echo "                                      on, with no hardware. NAME=, PORT=, IMAGE= and"
	@echo "                                      PLATFORM= override (use NAME=+PORT=+IMAGE= to run"
	@echo "                                      more than one at once); stop it with the SAME"
	@echo "                                      NAME=/PORT=: make pseudo-remote-down NAME=<n> PORT=<p>"
	@echo ""
	@echo "BUILD  (TARGET= is required for all of these)"
	@echo "  make sysroot TARGET=t        obtain the target's libraries+headers"
	@echo "                               override the description for one run with"
	@echo "                               PORT=, SYSROOT_PROVIDER= or SYSROOT_PROVIDER_ARGS="
	@echo "  make sysroot-info TARGET=t   what the sysroot actually contains"
	@echo "  make catalyst-llvm TARGET=t CATALYST=dir"
	@echo "                               cross-build Catalyst's LLVM for that target, for"
	@echo "                               components that link LLVM (example-executor)"
	@echo "  make build TARGET=t          build every component for that target"
	@echo "  make build TARGET=t COMPONENT=c    build just one"
	@echo "  make verify TARGET=t         re-check built artifacts against the target ABI"
	@echo "  make bundle TARGET=t BUNDLE=b      gather, verify and make deployable"
	@echo "  make deploy TARGET=t BUNDLE=b SSH=user@host [PORT=22]"
	@echo "                               copy that bundle to the machine and make it runnable"
	@echo ""
	@echo "CLEAN"
	@echo "  make clean-target TARGET=t   drop that target's build output (keeps sysroot)"
	@echo "  make sysroot-clean TARGET=t  drop that target's sysroot"
	@echo "  make clean                   drop all build output (keeps sysroots)"
	@echo "  make clean-all               drop build/ entirely"
	@echo ""
	@echo "SOURCE ROOTS"
	@echo "  Components declare external trees they need (e.g. CATALYST). Pass them on"
	@echo "  the command line, or set them once in config.mk (see config.mk.example)."
	@echo ""
	@echo "  targets: $(ALL_TARGETS)"

list-targets:
	@echo "Described machines (targets/*.conf):"
	@echo ""
	@echo "  ── this project's real machines ──"
	@for t in $(REAL_TARGETS); do \
	  desc=$$(sed -n 's/^TARGET_DESC=//p' $(ROOT_DIR)/targets/$$t.conf | tr -d '"' | head -1); \
	  triple=$$(sed -n 's/^TARGET_TRIPLE=//p' $(ROOT_DIR)/targets/$$t.conf | head -1); \
	  prov=$$(sed -n 's/^SYSROOT_PROVIDER=//p' $(ROOT_DIR)/targets/$$t.conf | head -1); \
	  sr="$(BUILD_DIR)/sysroots/$$t"; \
	  if [ -e "$$sr" ]; then state="sysroot ready"; else state="no sysroot yet"; fi; \
	  printf '  %-26s %-22s %-16s %s\n' "$$t" "$${triple:-<from host>}" "$${prov:-none}" "$$state"; \
	  printf '  %-26s %s\n' "" "$$desc"; \
	done
	@echo ""
	@echo "  ── examples and templates (illustrations, not real machines) ──"
	@for t in $(DEMO_TARGETS); do \
	  desc=$$(sed -n 's/^TARGET_DESC=//p' $(ROOT_DIR)/targets/$$t.conf | tr -d '"' | head -1); \
	  triple=$$(sed -n 's/^TARGET_TRIPLE=//p' $(ROOT_DIR)/targets/$$t.conf | head -1); \
	  prov=$$(sed -n 's/^SYSROOT_PROVIDER=//p' $(ROOT_DIR)/targets/$$t.conf | head -1); \
	  sr="$(BUILD_DIR)/sysroots/$$t"; \
	  if [ -e "$$sr" ]; then state="sysroot ready"; else state="no sysroot yet"; fi; \
	  printf '  %-26s %-22s %-16s %s\n' "$$t" "$${triple:-<from host>}" "$${prov:-none}" "$$state"; \
	  printf '  %-26s %s\n' "" "$$desc"; \
	done
	@echo ""
	@echo "Build one with:  make sysroot TARGET=<name> && make build TARGET=<name>"

list-components:
	@echo "Buildable components (components/*.conf):"
	@echo ""
# The '|| true' on the source-roots line is load-bearing: that test is the loop
# body's last command and a recipe's exit status is its last command's, so a
# component with no source roots (the last one alphabetically) made this recipe
# print correctly and then report 'Error 1'.
	@echo "  ── this project's real components ──"
	@for c in $(REAL_COMPONENTS); do \
	  kind=$$(sed -n 's/^COMPONENT_KIND=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  out=$$(sed -n 's/^COMPONENT_OUTPUT=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  roots=$$(sed -n 's/^COMPONENT_SOURCE_ROOTS=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  opt=$$(sed -n 's/^COMPONENT_OPTIONAL=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  printf '  %-30s %-16s %-28s %s\n' "$$c" "$${kind:-shared-library}" "$${out:-$$c}" \
	         "$$([ "$$opt" = yes ] && echo '(optional)')"; \
	  [ -n "$$roots" ] && printf '  %-30s needs source roots: %s\n' "" "$$roots" || true; \
	done
	@echo ""
	@echo "  ── examples and test fixtures (not deliverables) ──"
	@for c in $(DEMO_COMPONENTS); do \
	  kind=$$(sed -n 's/^COMPONENT_KIND=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  out=$$(sed -n 's/^COMPONENT_OUTPUT=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  roots=$$(sed -n 's/^COMPONENT_SOURCE_ROOTS=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  opt=$$(sed -n 's/^COMPONENT_OPTIONAL=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  printf '  %-30s %-16s %-28s %s\n' "$$c" "$${kind:-shared-library}" "$${out:-$$c}" \
	         "$$([ "$$opt" = yes ] && echo '(optional)')"; \
	  [ -n "$$roots" ] && printf '  %-30s needs source roots: %s\n' "" "$$roots" || true; \
	done

list-bundles:
	@echo "Deployable bundles (bundles/*.conf):"
	@echo ""
	@echo "  ── this project's deliverables ──"
	@for b in $(REAL_BUNDLES); do \
	  desc=$$(sed -n 's/^BUNDLE_DESC=//p' $(ROOT_DIR)/bundles/$$b.conf | tr -d '"' | head -1); \
	  printf '  %-32s %s\n' "$$b" "$$desc"; \
	done
	@echo ""
	@echo "  ── examples and test fixtures (not deliverables) ──"
	@for b in $(DEMO_BUNDLES); do \
	  desc=$$(sed -n 's/^BUNDLE_DESC=//p' $(ROOT_DIR)/bundles/$$b.conf | tr -d '"' | head -1); \
	  printf '  %-32s %s\n' "$$b" "$$desc"; \
	done

doctor:
	@TARGET='$(TARGET)' $(TOOLS_DIR)/doctor.sh $(ROOT_DIR)

quickstart:
	@$(TOOLS_DIR)/quickstart.sh $(ROOT_DIR)

# Tests the BUILD SYSTEM, not your project. A failure here means this tree is
# broken; run it after changing anything under mk/ or tools/.
test:
	@$(ROOT_DIR)/tests/run-tests.sh $(if $(strip $(VERBOSE)),-v,)

validate:
	@echo "Validating every description..."
	@# A temp file, not one under build/: validate must work on a pristine checkout
	@# where build/ does not exist yet. (It is also the first command a newcomer is
	@# likely to run, so it must not depend on a prior build.)
	@# Generate to a file rather than /dev/null, so completeness can be checked too.
	@# Discarding the output made this goal report every description valid on a host
	@# where the parser was aborting on each one — the validator itself failing open,
	@# which the tree treats as worse than having no validator.
	@err=$$(mktemp); gen=$$(mktemp); fail=0; \
	for f in $(ROOT_DIR)/targets/*.conf $(ROOT_DIR)/components/*.conf $(ROOT_DIR)/bundles/*.conf; do \
	  [ -e "$$f" ] || continue; \
	  case "$$f" in *TEMPLATE*) continue ;; esac; \
	  if $(TOOLS_DIR)/conf2mk.sh "$$f" >"$$gen" 2>"$$err" \
	     && $(TOOLS_DIR)/conf2mk.sh --check "$$gen" 2>>"$$err"; then \
	    printf '  ok    %s\n' "$${f#$(ROOT_DIR)/}"; \
	  else \
	    printf '  FAIL  %s\n' "$${f#$(ROOT_DIR)/}"; \
	    sed 's/^/        /' "$$err"; \
	    fail=1; \
	  fi; \
	done; \
	rm -f "$$err" "$$gen"; \
	echo ""; \
	if [ $$fail -eq 0 ]; then echo "All descriptions are valid."; else echo "Some descriptions are invalid (see above)."; exit 1; fi

# Cross-check that bundles only reference components that exist. A typo here
# otherwise surfaces at bundle time, after a full build.
check: validate
	@echo ""
	@echo "Cross-checking bundle -> component references..."
	@# Values are read through conf2mk.sh's shell view and eval'd, never with an ad-hoc
	@# sed. Two reasons, and the first one bit:
	@#
	@#   * This loop previously used  sed 's/^BUNDLE_\(OPTIONAL_\)\?COMPONENTS=//p'. The
	@#     '\?' is a GNU BRE extension; BSD sed reads it as a literal '?', so the pattern
	@#     matched NEITHER real key. $$refs was always empty, the inner loop never ran, and
	@#     this goal printed "ok every reference resolves" having checked nothing at all.
	@#     Measured: a bundle pointing at 'no-such-component-at-all' passed. One of the two
	@#     gates AGENTS.md requires before claiming a change works was inert on macOS.
	@#   * The generated view also strips quotes and trailing comments, so
	@#     BUNDLE_COMPONENTS="a b"  and  COMPONENT_DEPENDS=x  # temporary
	@#     resolve to what they mean rather than to what they literally say.
	@#
	@# The variables are cleared before each eval: one shell runs the whole loop, so a
	@# description that omits a key would otherwise silently inherit the previous one's.
	@fail=0; \
	for b in $(ALL_BUNDLES); do \
	  BUNDLE_COMPONENTS=; BUNDLE_OPTIONAL_COMPONENTS=; \
	  eval "$$($(TOOLS_DIR)/conf2mk.sh --shell $(ROOT_DIR)/bundles/$$b.conf)" || { \
	    printf '  FAIL  bundle %s could not be read\n' "$$b"; fail=1; continue; }; \
	  for r in $$BUNDLE_COMPONENTS $$BUNDLE_OPTIONAL_COMPONENTS; do \
	    if [ ! -e "$(ROOT_DIR)/components/$$r.conf" ]; then \
	      printf '  FAIL  bundle %s references unknown component %s\n' "$$b" "$$r"; fail=1; \
	    fi; \
	  done; \
	done; \
	for c in $(ALL_COMPONENTS); do \
	  COMPONENT_DEPENDS=; \
	  eval "$$($(TOOLS_DIR)/conf2mk.sh --shell $(ROOT_DIR)/components/$$c.conf)" || { \
	    printf '  FAIL  component %s could not be read\n' "$$c"; fail=1; continue; }; \
	  for d in $$COMPONENT_DEPENDS; do \
	    if [ ! -e "$(ROOT_DIR)/components/$$d.conf" ]; then \
	      printf '  FAIL  component %s depends on unknown component %s\n' "$$c" "$$d"; fail=1; \
	    fi; \
	  done; \
	done; \
	if [ $$fail -eq 0 ]; then echo "  ok    every reference resolves"; else exit 1; fi

# ─────────────────────────────────────────────────────────────────────────────
# Target resolution — everything below needs TARGET=
# ─────────────────────────────────────────────────────────────────────────────

ifeq ($(filter $(NO_TARGET_GOALS),$(MAKECMDGOALS)),)
  ifneq ($(MAKECMDGOALS),)
    ifeq ($(strip $(TARGET)),)
      $(error TARGET= is required for '$(MAKECMDGOALS)'.$(NEWLINE)\
        Available targets: $(ALL_TARGETS)$(NEWLINE)\
        e.g.  make $(firstword $(MAKECMDGOALS)) TARGET=$(firstword $(ALL_TARGETS)))
    endif
    TARGET_CONF := $(ROOT_DIR)/targets/$(TARGET).conf
    ifeq ($(filter $(TARGET_CREATING_GOALS),$(MAKECMDGOALS)),)
      ifeq ($(wildcard $(TARGET_CONF)),)
        $(error No description for target '$(TARGET)' (looked for targets/$(TARGET).conf).$(NEWLINE)\
          Available: $(ALL_TARGETS)$(NEWLINE)\
          Create one with:  make new-target TARGET=$(TARGET)$(NEWLINE)\
          Or from a live machine:  make probe TARGET=$(TARGET) SSH=user@host)
      endif

    # Regenerate the Make view of the description whenever it changes. This is the
    # mechanism that lets one file serve both shell and Make with no duplication.
    GEN_TARGET_MK := $(GEN_DIR)/targets/$(TARGET).mk
    $(shell mkdir -p $(GEN_DIR)/targets)
    # Check the EXIT STATUS, not merely whether the file exists. A previous run may
    # have left a valid .mk behind; testing only for existence would then use that
    # stale file after the description was edited into an invalid state — reporting
    # success while silently building against the old settings, and printing the new
    # description's path as its source.
    #
    # And check COMPLETENESS as well as the status, because a shell can stop half way
    # through a file and still exit 0 (see mk/component.mk for the observed case).
    # Scratch names carry the shell's PID ($$$$), so two concurrent `make` invocations in
    # ONE tree for the SAME target do not share a .tmp/.err and interleave into each other's.
    # The final `mv` was already atomic — a half-written file never appeared as the real .mk,
    # so the race produced a spurious read error, never a wrong build — but a per-target
    # scratch name still let two documented read-only goals (show-target & sysroot-info) run
    # in parallel and fail on a file the reader has never heard of. The error text is captured
    # into the make variable here rather than read from a fixed file afterwards, precisely so
    # no fixed filename has to survive between the two steps.
    _GEN_RC := $(shell t=$(GEN_TARGET_MK).$$$$.tmp; e=$(GEN_TARGET_MK).$$$$.err; \
            if $(TOOLS_DIR)/conf2mk.sh $(TARGET_CONF) > $$t 2>$$e \
               && $(TOOLS_DIR)/conf2mk.sh --check $$t 2>>$$e; then \
                 mv $$t $(GEN_TARGET_MK); rm -f $$e; echo ok; \
            else \
                 rm -f $$t; sed 's/^/GENERR /' $$e; rm -f $$e; \
            fi)
    ifneq ($(_GEN_RC),ok)
      $(error Target description targets/$(TARGET).conf could not be read:$(NEWLINE)$(subst GENERR ,,$(_GEN_RC)))
    endif

    include $(GEN_TARGET_MK)
    include $(ROOT_DIR)/mk/derive.mk

    # The Make-to-shell interface, for whole-target tools that need a resolved target in
    # their environment (tools/build-catalyst-llvm.sh via gen-cmake-toolchain.sh).
    #
    # GOAL-SCOPED, and it must stay that way. Exporting these unconditionally breaks
    # `make build`: conf2mk emits every setting with '?=' so a command line can override it,
    # an environment variable outranks '?=', and Make treats an inherited environment value
    # as RECURSIVELY EXPANDED. So TARGET_RPATH travelled into the component sub-make as
    # '$ORIGIN', got expanded a second time, and '$O' (an unset variable) left an RPATH of
    # literally 'RIGIN' — the exact bug tests/run-tests.sh guards against in descriptions,
    # reintroduced through the environment instead. Caught by the relocatable-bundle test.
    ifneq ($(filter catalyst-llvm,$(MAKECMDGOALS)),)
      include $(ROOT_DIR)/mk/exports.mk
    endif
    endif
  endif
endif

# ─────────────────────────────────────────────────────────────────────────────
# Sysroot
# ─────────────────────────────────────────────────────────────────────────────

# ── one-off overrides for the fetch ──────────────────────────────────────────
#
# The provider and its arguments live in the target description, and get-sysroot.sh
# reads them out of that file itself. So a plain `make sysroot SYSROOT_PROVIDER_ARGS=…`
# was accepted and then silently ignored: Make's value never reached the script. These
# make the override real, for trying one host, port or path without committing it to a
# description that other people share.
#
# $(origin) is what distinguishes "the user typed this" from "conf2mk generated it".
# Both arrive as ordinary Make variables; only the former may outrank the file.
ifeq ($(origin SYSROOT_PROVIDER),command line)
  export SYSROOT_PROVIDER_OVERRIDE := $(SYSROOT_PROVIDER)
endif

_SYSROOT_ARGS_OVERRIDE :=
ifeq ($(origin SYSROOT_PROVIDER_ARGS),command line)
  _SYSROOT_ARGS_OVERRIDE := $(SYSROOT_PROVIDER_ARGS)
endif

# PORT= is a shorthand for the one override people actually want (ssh on a non-default
# port), and it MERGES with whatever else the description already says rather than
# replacing it — so you keep host= without retyping it. Any existing port= is dropped
# first, because two port= words would leave the provider picking the last one silently.
#
# It is merged into the args rather than being its own concept so that providers stay
# free to have no port: 'dir' answers port= with its own message listing what it does
# accept, which beats Make guessing which providers are network providers.
#
# What PORT= merges INTO depends on whether the provider itself was overridden: the
# description's args describe the description's provider, so inheriting 'path=/' from a
# 'dir' description while switching to ssh-rsync would hand that provider an argument it
# rightly rejects. Overriding the provider therefore starts from empty args.
ifneq ($(strip $(PORT)),)
  ifneq ($(_SYSROOT_ARGS_OVERRIDE),)
    _SYSROOT_ARGS_BASE := $(_SYSROOT_ARGS_OVERRIDE)
  else ifeq ($(origin SYSROOT_PROVIDER),command line)
    _SYSROOT_ARGS_BASE :=
  else
    _SYSROOT_ARGS_BASE := $(SYSROOT_PROVIDER_ARGS)
  endif
  _SYSROOT_ARGS_OVERRIDE := $(filter-out port=%,$(_SYSROOT_ARGS_BASE)) port=$(PORT)
endif

ifneq ($(strip $(_SYSROOT_ARGS_OVERRIDE)),)
  # $(strip) because an empty base plus ' port=N' leaves a leading space that the
  # provider would parse as an empty word and the banner would print as a gap.
  export SYSROOT_PROVIDER_ARGS_OVERRIDE := $(strip $(_SYSROOT_ARGS_OVERRIDE))
endif

sysroot:
	@# TARGET_TRIPLE is passed explicitly because derive.mk may have resolved it from
	@# the host (a native target can leave it blank in the description); the shell
	@# tool must see the resolved value, not the file's empty one.
	@$(TOOLS_DIR)/get-sysroot.sh $(ROOT_DIR) $(TARGET) $(SYSROOT_DIR) $(TARGET_TRIPLE)

# ─────────────────────────────────────────────────────────────────────────────
# Cross-built dependencies
# ─────────────────────────────────────────────────────────────────────────────

# Some components link LLVM itself (catalyst-executor JITs code ON the target), so they need
# LLVM libraries of the target's architecture at the version Catalyst pins. Neither Catalyst's
# host build (right version, wrong arch) nor a distro llvm-<N>-dev in the rootfs (right arch,
# usually the wrong version) satisfies both, so the pinned checkout gets cross-compiled with
# this tree's own toolchain and sysroot.
#
# Separate from 'build', and never a prerequisite of it: this takes a long time and most
# components do not need it, so it is something you ask for explicitly and once.
#
# COMPILER_LAUNCHER is spelled and defaulted exactly as in catalyst/mlir/Makefile — ccache
# when installed — because this compiles much of the same source as Catalyst's own build and
# should share its cache. Pass COMPILER_LAUNCHER= to build without.
COMPILER_LAUNCHER ?= $(shell command -v ccache 2>/dev/null)
export COMPILER_LAUNCHER

catalyst-llvm:
	@if [ -z "$(strip $(CATALYST))" ]; then \
	  echo "CATALYST= is required: make catalyst-llvm TARGET=$(TARGET) CATALYST=/path/to/catalyst"; \
	  echo ""; \
	  echo "Cross-builds catalyst/mlir/llvm-project for this target, so components that link"; \
	  echo "LLVM (example-executor) get target-architecture libraries at Catalyst's own LLVM"; \
	  echo "version. Reuses the host build's llvm-tblgen, so build that first."; \
	  exit 1; \
	fi
	@# The generated toolchain file is what makes this LLVM agree with every other artifact for
	@# this target — same triple, same sysroot, same C++ standard. Generated here rather than
	@# assumed present, because a target may never have had a cmake component built.
	@mkdir -p $(dir $(CMAKE_TOOLCHAIN_FILE))
	@$(TOOLS_DIR)/gen-cmake-toolchain.sh > $(CMAKE_TOOLCHAIN_FILE)
	@$(TOOLS_DIR)/build-catalyst-llvm.sh $(ROOT_DIR) $(TARGET) $(CATALYST) $(CMAKE_TOOLCHAIN_FILE) $(LLVM_OUTDIR)

sysroot-info:
	@$(TOOLS_DIR)/sysroot-inspect.sh report "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)"

sysroot-clean:
	@if [ -L "$(SYSROOT_DIR)" ]; then \
	  echo "removing symlink $(SYSROOT_DIR) (the referenced tree is left alone)"; \
	  rm -f "$(SYSROOT_DIR)"; \
	elif [ -d "$(SYSROOT_DIR)" ]; then \
	  echo "removing $(SYSROOT_DIR)"; \
	  rm -rf "$(SYSROOT_DIR)"; \
	else \
	  echo "no sysroot at $(SYSROOT_DIR)"; \
	fi

# ── a target machine to practise on, when you have no hardware ───────────────
# Starts an aarch64 container reachable over ssh, so the whole workflow — probe, sysroot,
# build, verify, deploy — can be driven for real on one laptop. See README.md.
pseudo-remote:
	@NAME=$(or $(NAME),crossbuild-pseudo-remote) PORT=$(or $(PORT),2222) \
	  PLATFORM=$(or $(PLATFORM),linux/arm64) IMAGE=$(or $(IMAGE),crossbuild-pseudo-remote:latest) \
	  $(ROOT_DIR)/examples/docker/pseudo-remote.sh $(or $(ACTION),up)

pseudo-remote-down:
	@NAME=$(or $(NAME),crossbuild-pseudo-remote) PORT=$(or $(PORT),2222) \
	  $(ROOT_DIR)/examples/docker/pseudo-remote.sh down

probe:
	@if [ -z "$(SSH)" ]; then \
	  echo "SSH= is required: make probe TARGET=$(TARGET) SSH=user@host [PORT=22]"; \
	  echo ""; \
	  echo "Runs sysroot/probe/probe-target.sh on that machine and writes a target"; \
	  echo "description from what it finds: glibc version, C++ ABI level and ELF"; \
	  echo "interpreter path, which are the three values you must not guess."; \
	  echo ""; \
	  echo "On a description that already exists, only those probed facts are updated."; \
	  echo "The provider, TARGET_CPU, flags and comments are kept. FRESH=1 regenerates"; \
	  echo "the whole file instead."; \
	  exit 1; \
	fi
	@FRESH="$(FRESH)" $(TOOLS_DIR)/probe-over-ssh.sh $(ROOT_DIR) $(TARGET) $(SSH) $(or $(PORT),22)

# ─────────────────────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────────────────────

# Which components to build: one if COMPONENT= is given, else all of them.
#
# When building all, order them so a component's dependencies come FIRST. The naive
# alphabetical order is wrong: mk/rules.mk lists a dependency's artifact as a
# prerequisite with no rule to build it, so a component whose dependency sorts later
# fails with "No rule to make target". Worse, if that component is
# COMPONENT_OPTIONAL=yes the failure is downgraded to "skipped" and it is then
# silently omitted from any bundle — a missing library discovered on the target.
#
# tools/order-components.sh does the topological sort and reports a dependency cycle
# as an error rather than looping.
ifeq ($(strip $(COMPONENT)),)
  BUILD_COMPONENTS := $(shell $(TOOLS_DIR)/order-components.sh $(ROOT_DIR) $(ALL_COMPONENTS))
else
  # One component was named. Build its dependencies first too — asking for a
  # component and getting a link error about a sibling you did not mention is a poor
  # experience, and the fix ("build the other one first") is not discoverable.
  BUILD_COMPONENTS := $(shell $(TOOLS_DIR)/order-components.sh $(ROOT_DIR) --with-deps $(COMPONENT))
endif

build:
	@# COMPONENT= may name several, space-separated: order-components.sh already takes a list
	@# and resolves dependencies across it, so each word is validated on its own rather than
	@# the whole value as one filename.
	@for c in $(COMPONENT); do \
	  if [ ! -e "$(ROOT_DIR)/components/$$c.conf" ]; then \
	    echo "No such component '$$c'."; \
	    echo "Available: $(ALL_COMPONENTS)"; \
	    exit 1; \
	  fi; \
	done
	@$(TOOLS_DIR)/sysroot-inspect.sh probe "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)"
	@# Silent unless the sysroot can be run against but not linked against — a rootfs
	@# copied from a machine with no -dev packages. Advisory, never fatal: the probe
	@# above owns the decision about whether to proceed. Placed once here rather than in
	@# mk/rules.mk, which would repeat it for every component in the run.
	@$(TOOLS_DIR)/sysroot-inspect.sh linkability "$(SYSROOT_DIR)" "$(TARGET_TRIPLE)" "$(TARGET_STDLIB)"
	@echo ""
	@echo "building for target '$(TARGET)' ($(TARGET_TRIPLE))"
	@echo ""
	@# COMPONENT_OPTIONAL means "a bundle can live without this". It must NOT apply to the
	@# component the caller actually named: there, the failure IS the answer to the
	@# question, and reporting EXIT=0 with "skipped (optional, failed)" is how a component
	@# that built nothing usable went unnoticed.
	@#
	@# The test is against the NAMED component, not against COMPONENT being empty. With
	@# COMPONENT= set, BUILD_COMPONENTS is 'order-components.sh --with-deps', so the list
	@# also holds dependencies nobody asked for: those keep their optionality, and only
	@# the one on the command line loses it.
	@failed=""; skipped=""; built=""; \
	for c in $(BUILD_COMPONENTS); do \
	  opt=$$(sed -n 's/^COMPONENT_OPTIONAL=//p' $(ROOT_DIR)/components/$$c.conf | head -1); \
	  if $(MAKE) --no-print-directory -f $(ROOT_DIR)/mk/component.mk \
	       ROOT_DIR=$(ROOT_DIR) TARGET=$(TARGET) COMPONENT=$$c component; then \
	    built="$$built $$c"; \
	  else \
	    if [ "$$opt" = yes ] && [ "$$c" != "$(COMPONENT)" ]; then \
	      echo "  ... '$$c' failed but is optional; continuing"; \
	      skipped="$$skipped $$c"; \
	    else \
	      if [ "$$opt" = yes ]; then \
	        echo "  ... '$$c' is optional, but you asked for it by name — reporting the failure"; \
	      fi; \
	      failed="$$failed $$c"; \
	    fi; \
	  fi; \
	done; \
	echo ""; \
	echo "built:  $${built:-nothing}"; \
	[ -n "$$skipped" ] && echo "skipped (optional, failed): $$skipped"; \
	if [ -n "$$failed" ]; then echo "FAILED: $$failed"; exit 1; fi; \
	echo ""; \
	echo "next:  make verify TARGET=$(TARGET)"; \
	compdir="$(BUILD_DIR)/$(TARGET)/components"; \
	suggestable=""; \
	for b in $(REAL_BUNDLES) $(DEMO_BUNDLES); do \
	  reqs=$$(sed -n 's/^BUNDLE_COMPONENTS=//p' $(ROOT_DIR)/bundles/$$b.conf | head -1); \
	  ok=1; [ -n "$$reqs" ] || ok=0; \
	  for c in $$reqs; do \
	    out=$$($(TOOLS_DIR)/component-output.sh $(ROOT_DIR) $$c 2>/dev/null); \
	    [ -n "$$out" ] && [ -e "$$compdir/$$c/$$out" ] || { ok=0; break; }; \
	  done; \
	  [ "$$ok" = 1 ] && suggestable="$$suggestable $$b"; \
	done; \
	if [ -n "$$suggestable" ]; then \
	  echo "       make bundle TARGET=$(TARGET) BUNDLE=$$(echo $$suggestable | awk '{print $$1}')"; \
	  echo ""; \
	  echo "       ready to bundle for $(TARGET) (all their components are built):$$suggestable"; \
	else \
	  echo "       make bundle TARGET=$(TARGET) BUNDLE=<name>    # make list-bundles"; \
	fi; \
	echo ""; \
	echo "       all deliverables:  $(REAL_BUNDLES)"; \
	echo "       examples/fixtures:  $(DEMO_BUNDLES)"

verify:
	@found=0; fail=0; \
	for c in $(ALL_COMPONENTS); do \
	  out=$$($(TOOLS_DIR)/component-output.sh $(ROOT_DIR) $$c 2>/dev/null); \
	  art="$(TARGET_BUILD_DIR)/components/$$c/$$out"; \
	  if [ -e "$$art" ]; then \
	    found=1; \
	    $(TOOLS_DIR)/verify-artifact.sh "$$art" --target-conf $(TARGET_CONF) \
	      --triple "$(TARGET_TRIPLE)" --arch "$(TARGET_ARCH)" \
	      $(if $(STRICT),--strict,) || fail=1; \
	  fi; \
	done; \
	if [ $$found -eq 0 ]; then \
	  echo "Nothing built for '$(TARGET)' yet. Run: make build TARGET=$(TARGET)"; \
	  exit 1; \
	fi; \
	exit $$fail

show-target:
	@echo "Target '$(TARGET)' — fully resolved"
	@echo "  description file   $(TARGET_CONF_FILE)"
	@echo ""
	@echo "  TARGET_TRIPLE      $(TARGET_TRIPLE)"
	@echo "  TARGET_ARCH        $(TARGET_ARCH)"
	@echo "  TARGET_CPU         $(if $(strip $(TARGET_CPU)),$(TARGET_CPU) (via -$(TARGET_CPU_FLAG)=),<generic — runs on every chip of this arch>)"
	@echo "  TARGET_LIBC        $(TARGET_LIBC) $(if $(strip $(TARGET_LIBC_VERSION)),$(TARGET_LIBC_VERSION),<unspecified: the ABI ceiling check is DISABLED>)"
	@echo "  TARGET_CXXABI_MAX  $(if $(strip $(TARGET_CXXABI_MAX)),$(TARGET_CXXABI_MAX),<unspecified: not checked>)"
	@echo "  interpreter        $(if $(strip $(TARGET_DYNAMIC_LINKER)),$(TARGET_DYNAMIC_LINKER),<compiler default from sysroot>)"
	@echo "  TARGET_GPU_ARCH    $(if $(strip $(TARGET_GPU_ARCH)),$(TARGET_GPU_ARCH)$(if $(strip $(GPU_ARCH)), (from GPU_ARCH= on this command line),),<unset: a component needing device code will refuse>)"
	@echo "  GPU vendor         $(if $(strip $(TARGET_GPU_VENDOR)),$(TARGET_GPU_VENDOR) (derived from how the arch is spelled),$(if $(strip $(TARGET_GPU_ARCH)),<unrecognised arch: expected gfx<n> or sm_<n>>,<none: no GPU arch set>))"
	@echo "  GPU arch flag      $(if $(strip $(TARGET_GPU_ARCH_FLAG)),$(TARGET_GPU_ARCH_FLAG),<none>)"
	@echo ""
	@echo "  toolchain          $(TOOLCHAIN_KIND) at $(TOOLCHAIN_ROOT)"
	@echo "  C compiler         $(TARGET_CC)"
	@echo "  C++ compiler       $(TARGET_CXX)"
	@echo "  linker             $(TARGET_LINKER)"
	@echo "  C++ stdlib         $(TARGET_STDLIB)   (C++$(TARGET_CXX_STANDARD))"
	@echo ""
	@echo "  sysroot provider   $(SYSROOT_PROVIDER) $(SYSROOT_PROVIDER_ARGS)"
	@echo "  sysroot dir        $(SYSROOT_DIR)"
	@echo "  build dir          $(TARGET_BUILD_DIR)"
	@echo "  deploy dir         $(TARGET_DEPLOY_DIR)  (on the target)"
	@# Single-quoted for the same reason as the link line below: TARGET_RPATH is literally
	@# $$ORIGIN, and an unquoted echo hands that to the shell, which expands it to nothing.
	@# The row read blank in the one command whose promise is "every resolved setting" —
	@# four lines above a link flag visibly setting it.
	@printf '  rpath              %s\n' '$(subst ','"'"',$(TARGET_RPATH))'
	@echo ""
	@echo "  These are the exact flags every component gets. Nothing else adds"
	@echo "  target-specific flags anywhere:"
	@echo ""
	@# The link flags contain -Wl,-rpath,'$$ORIGIN' — with its own single quotes, which
	@# is exactly right when handed to the compiler. For DISPLAY we strip those inner
	@# quotes, because they would otherwise close the quoting around this printf
	@# argument and let the shell expand $$ORIGIN to nothing. What the compiler
	@# actually receives is shown verbatim in the build output.
	@printf '  compile: %s\n' '$(subst ','"'"',$(TARGET_CXX_FLAGS) $(SYSROOT_CXX_FLAGS))'
	@echo ""
	@printf '  link:    %s\n' '$(subst ',,$(TARGET_LINK_FLAGS) $(SYSROOT_LINK_FLAGS))'

show-component:
	@if [ -z "$(COMPONENT)" ]; then echo "COMPONENT= is required. Available: $(ALL_COMPONENTS)"; exit 1; fi
	@$(MAKE) --no-print-directory -f $(ROOT_DIR)/mk/component.mk \
	   ROOT_DIR=$(ROOT_DIR) TARGET=$(TARGET) COMPONENT=$(COMPONENT) component-info

# ─────────────────────────────────────────────────────────────────────────────
# Bundle
# ─────────────────────────────────────────────────────────────────────────────

bundle:
	@if [ -z "$(BUNDLE)" ]; then \
	  echo "BUNDLE= is required. Available: $(ALL_BUNDLES)"; \
	  echo "e.g. make bundle TARGET=$(TARGET) BUNDLE=$(firstword $(ALL_BUNDLES))"; \
	  exit 1; \
	fi
	@# TARGET_STRIP/TARGET_READELF are derived (not description keys), so pass them
	@# through the environment or the bundler silently falls back to generic names —
	@# which on a cross build could strip with the wrong architecture's tool.
	@# TARGET_RPATH is passed as the 5th argument for the same reason as the triple: a
	@# portable description leaves it blank and derive.mk resolves it per binary format.
	@# STRICT= reached `verify` and stopped there, so the one command that produces the
	@# thing you actually ship could never be made strict — a warning such as
	@# "architecture: cannot check" still ended in "bundle ready" and exit 0.
	@BUILD_DIR=$(BUILD_DIR) TARGET_STRIP=$(TARGET_STRIP) TARGET_READELF=$(TARGET_READELF) \
	  TARGET_CXX=$(TARGET_CXX) STRICT=$(STRICT) \
	  $(TOOLS_DIR)/make-bundle.sh $(ROOT_DIR) $(TARGET) $(BUNDLE) $(TARGET_TRIPLE) '$(TARGET_RPATH)' '$(SYSROOT_DIR)'
	@# Publish it under one root, as build/bundles/<bundle>.
	@#
	@# A bundle is built per target, so build/<target>/bundles/<bundle> puts two machines' stacks
	@# in different parents. What consumes them wants the opposite: `deploy` entries in
	@# config/machines.toml are names resolved against a SINGLE bundle root, one subdirectory per
	@# machine. Without this, pointing BACKLINE_BUNDLES at anything meant staging the bundles into
	@# a directory by hand after every build.
	@#
	@# A link rather than a copy, so a rebuild is picked up with nothing to re-stage. It is
	@# replaced, not added to, because a bundle name identifies one stack.
	@mkdir -p $(BUILD_DIR)/bundles
	@rm -rf $(BUILD_DIR)/bundles/$(BUNDLE)
	@ln -s ../$(TARGET)/bundles/$(BUNDLE) $(BUILD_DIR)/bundles/$(BUNDLE)
	@printf '\npublished: %s\n' "$(BUILD_DIR)/bundles/$(BUNDLE)"
	@printf '           point BACKLINE_BUNDLES at %s\n\n' "$(BUILD_DIR)/bundles"

# Copy a bundle to the machine and make it runnable. A thin wrapper over the deploy script the
# bundler generates, so that every step of the workflow is a make goal and nobody has to know
# the layout of build/ to finish the job.
_DEPLOY_SCRIPT = $(BUILD_DIR)/$(TARGET)/bundles/$(BUNDLE)/deploy.sh

deploy:
	@if [ -z "$(BUNDLE)" ] || [ -z "$(SSH)" ]; then \
	  echo "BUNDLE= and SSH= are required:"; \
	  echo "  make deploy TARGET=$(TARGET) BUNDLE=$(firstword $(REAL_BUNDLES) $(ALL_BUNDLES)) SSH=user@host [PORT=22]"; \
	  echo ""; \
	  echo "Copies the bundle to that machine and reports where it landed. Build it first with"; \
	  echo "  make bundle TARGET=$(TARGET) BUNDLE=<name>"; \
	  exit 1; \
	fi
	@if [ ! -x "$(_DEPLOY_SCRIPT)" ]; then \
	  echo "No deploy script at $(_DEPLOY_SCRIPT)."; \
	  echo "Bundles are generated, not committed — build it first:"; \
	  echo "  make bundle TARGET=$(TARGET) BUNDLE=$(BUNDLE)"; \
	  exit 1; \
	fi
	@$(_DEPLOY_SCRIPT) $(SSH) $(or $(PORT),22)

# ─────────────────────────────────────────────────────────────────────────────
# New target from template
# ─────────────────────────────────────────────────────────────────────────────

new-target:
	@if [ -z "$(TARGET)" ]; then echo "usage: make new-target TARGET=<name>"; exit 1; fi
	@if [ -e "$(ROOT_DIR)/targets/$(TARGET).conf" ]; then \
	  echo "targets/$(TARGET).conf already exists; not overwriting."; exit 1; \
	fi
	@sed 's/^TARGET_NAME=.*/TARGET_NAME=$(TARGET)/' \
	    $(ROOT_DIR)/targets/TEMPLATE.conf.in > $(ROOT_DIR)/targets/$(TARGET).conf
	@echo "created targets/$(TARGET).conf"
	@echo ""
	@echo "Fill in TARGET_TRIPLE and the ABI fields. If the machine exists and you"
	@echo "can reach it, do not fill them in by hand — let it tell you:"
	@echo "    make probe TARGET=$(TARGET) SSH=user@host"

# ─────────────────────────────────────────────────────────────────────────────
# Cleaning
# ─────────────────────────────────────────────────────────────────────────────

clean-target:
	@rm -rf $(TARGET_BUILD_DIR)
	@echo "removed $(TARGET_BUILD_DIR) (sysroot kept — re-fetching one is slow)"

clean:
	@# Keeps build/sysroots because re-acquiring a sysroot can take many minutes
	@# over a slow link, while everything else is cheap to rebuild.
	@find $(BUILD_DIR) -mindepth 1 -maxdepth 1 ! -name sysroots -exec rm -rf {} + 2>/dev/null || true
	@echo "removed all build output; sysroots kept (use clean-all to drop those too)"

clean-all:
	@rm -rf $(BUILD_DIR)
	@echo "removed $(BUILD_DIR)"
