# ─────────────────────────────────────────────────────────────────────────────
# mk/exports.mk — the Make-to-shell interface.
#
# The resolved target settings that shell tools need in their environment, in ONE place.
# tools/gen-cmake-toolchain.sh reads these, and so does anything else that has to see a
# target the way the recipes see it (tools/build-catalyst-llvm.sh).
#
# Listed explicitly rather than `export` with no arguments: that keeps the child
# environment small, and makes the interface between Make and the scripts greppable —
# you can answer "where does this script get TARGET_CXX from" by reading one file.
#
# Included by mk/component.mk (the per-component build) and by the top-level Makefile
# (whole-target operations). It exists as its own file because two copies of this list
# would drift, and the failure mode of drift is a tool silently seeing an empty value and
# falling back to a default — exactly the class of silent wrongness this tree avoids.
# ─────────────────────────────────────────────────────────────────────────────

export TARGET_NAME TARGET_TRIPLE TARGET_ARCH TARGET_CPU TARGET_CPU_FLAG TARGET_BINFMT
export TARGET_LIBC TARGET_LIBC_VERSION TARGET_CXXABI_MAX TARGET_DYNAMIC_LINKER
export TARGET_CFLAGS TARGET_CXXFLAGS TARGET_LDFLAGS TARGET_RPATH
export TARGET_LINKER TARGET_STDLIB TOOLCHAIN_KIND TARGET_CONF_FILE
export TARGET_CC TARGET_CXX TARGET_AR TARGET_RANLIB TARGET_STRIP
export TARGET_OBJCOPY TARGET_READELF SYSROOT_DIR
export TARGET_CXX_STANDARD TARGET_STD_FLAG

# The discovered sysroot paths must reach the cmake generator too, or a cmake-driven
# component would compile against different headers than a directly-compiled one.
export SYSROOT_CXX_FLAGS SYSROOT_LINK_FLAGS
