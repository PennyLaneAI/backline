# ─────────────────────────────────────────────────────────────────────────────
# mk/component.mk — builds exactly ONE component for ONE target.
#
# Invoked as a sub-make by the top-level Makefile:
#     make -f mk/component.mk ROOT_DIR=… TARGET=… COMPONENT=… component
#
# Why a sub-make rather than doing it all in one Makefile: each component brings
# its own set of COMPONENT_* variables, and Make has one global variable namespace
# per invocation. Building N components in one process would require either
# per-component variable prefixes (unreadable) or careful clearing between
# components (fragile — one forgotten variable silently leaks a flag from the
# previous component into the next).
#
# One process per component makes leakage structurally impossible and gives each
# component a clean, independently reproducible command line. The cost is a few
# milliseconds of process startup, which is nothing next to a compile.
# ─────────────────────────────────────────────────────────────────────────────

ifndef ROOT_DIR
  $(error mk/component.mk must be invoked with ROOT_DIR=; use the top-level Makefile)
endif
ifndef TARGET
  $(error mk/component.mk must be invoked with TARGET=)
endif
ifndef COMPONENT
  $(error mk/component.mk must be invoked with COMPONENT=)
endif

define NEWLINE


endef

BUILD_DIR := $(ROOT_DIR)/build
TOOLS_DIR := $(ROOT_DIR)/tools
GEN_DIR   := $(BUILD_DIR)/generated

-include $(ROOT_DIR)/config.mk

TARGET_CONF    := $(ROOT_DIR)/targets/$(TARGET).conf
COMPONENT_CONF := $(ROOT_DIR)/components/$(COMPONENT).conf

ifeq ($(wildcard $(TARGET_CONF)),)
  $(error No target description: $(TARGET_CONF))
endif
ifeq ($(wildcard $(COMPONENT_CONF)),)
  $(error No component description: $(COMPONENT_CONF))
endif

# Generate and include both descriptions. Order matters: the target first, so that
# derive.mk's defaults are in place, then the component, which may reference them.
$(shell mkdir -p $(GEN_DIR)/targets $(GEN_DIR)/components)

GEN_TARGET_MK    := $(GEN_DIR)/targets/$(TARGET).mk
GEN_COMPONENT_MK := $(GEN_DIR)/components/$(COMPONENT).mk

# Generate BOTH views, and abort on a validation failure.
#
# CRITICAL: the error output must NOT be discarded and the exit status must be
# checked. Writing straight to the destination with `2>/dev/null` silently truncates
# it at the first bad line and then `include`s the partial file — so a single typo'd
# key deletes every setting after it, the build reports success, and the artifact is
# built with flags the description clearly asked for but that never arrived. Observed:
# a typo above COMPONENT_CXXFLAGS produced a binary missing those defines, with no
# message anywhere.
#
# Writing to a .tmp and moving it only on success also guarantees we never leave a
# truncated file behind for a later invocation to pick up.
#
# AND the exit status is not the whole test. It catches the generator REFUSING a bad
# description, which is what it was written for. It does not catch the generator being
# cut off part-way: a shell that hits an expansion error abandons the enclosing loop,
# carries on after it, and exits 0 — 'set -e' does not fire. That produced a .mk holding
# one key on macOS bash 3.2, accepted here as valid, with every later setting silently
# reverting to its default. `--check` asks the generator whether its own output is whole;
# see tools/conf2mk.sh for the marker it looks for.
_GEN_TARGET_RC := $(shell $(TOOLS_DIR)/conf2mk.sh $(TARGET_CONF) > $(GEN_TARGET_MK).tmp 2> $(GEN_TARGET_MK).err \
                      && $(TOOLS_DIR)/conf2mk.sh --check $(GEN_TARGET_MK).tmp 2>> $(GEN_TARGET_MK).err \
                      && mv $(GEN_TARGET_MK).tmp $(GEN_TARGET_MK) && rm -f $(GEN_TARGET_MK).err && echo ok)
ifneq ($(_GEN_TARGET_RC),ok)
  $(error Target description could not be read: $(TARGET_CONF)$(NEWLINE)$(shell cat $(GEN_TARGET_MK).err 2>/dev/null))
endif

_GEN_COMPONENT_RC := $(shell $(TOOLS_DIR)/conf2mk.sh $(COMPONENT_CONF) > $(GEN_COMPONENT_MK).tmp 2> $(GEN_COMPONENT_MK).err \
                         && $(TOOLS_DIR)/conf2mk.sh --check $(GEN_COMPONENT_MK).tmp 2>> $(GEN_COMPONENT_MK).err \
                         && mv $(GEN_COMPONENT_MK).tmp $(GEN_COMPONENT_MK) && rm -f $(GEN_COMPONENT_MK).err && echo ok)
ifneq ($(_GEN_COMPONENT_RC),ok)
  $(error Component description could not be read: $(COMPONENT_CONF)$(NEWLINE)$(shell cat $(GEN_COMPONENT_MK).err 2>/dev/null))
endif

include $(GEN_TARGET_MK)
include $(ROOT_DIR)/mk/derive.mk
include $(GEN_COMPONENT_MK)

# The list of exported settings lives in mk/exports.mk, shared with the top-level Makefile
# so the two cannot drift.
include $(ROOT_DIR)/mk/exports.mk

include $(ROOT_DIR)/mk/rules.mk
