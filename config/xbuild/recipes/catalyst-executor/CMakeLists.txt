# catalyst-executor — Catalyst's ORC EPC executor, cross-built for a target.
#
# The recipe for a real artifact, not an example: components/example-executor.conf points
# COMPONENT_CMAKE_SOURCE_DIR here. The reusable half — choosing an LLVM this target can link —
# is cmake/CrossbuildFindLLVM.cmake. The source stays in the Catalyst checkout so a target
# binary and the host build come from one implementation.

cmake_minimum_required(VERSION 3.20)
# C is enabled although nothing here is C: LLVMConfig.cmake's FindTerminfo/FindFFI call
# check_c_source_compiles, and with only CXX the configure aborts with
#     check_source_compiles: C: needs to be enabled before use.
project(catalyst_executor C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(CATALYST_SRC "" CACHE PATH "Path to a Catalyst checkout providing the executor source")
set(EXECUTOR_SRC "${CATALYST_SRC}/runtime/lib/executor/executor.cpp")
if(NOT CATALYST_SRC OR NOT EXISTS "${EXECUTOR_SRC}")
    message(FATAL_ERROR
        "CATALYST_SRC must point at a Catalyst checkout containing "
        "runtime/lib/executor/executor.cpp (looked for '${EXECUTOR_SRC}'). "
        "Pass -DCATALYST_SRC=/path/to/catalyst, or build via the Makefile with CATALYST=...")
endif()

# ── which LLVM ───────────────────────────────────────────────────────────────
#
# Catalyst pins an LLVM and this source is written against it, so that is the default;
# `make catalyst-llvm TARGET=<t>` builds the per-architecture copy this finds. A system LLVM is
# opt-in because it is usually the wrong version. Measured against executor.cpp:
#   19 and below -> fatal error: 'llvm/ExecutionEngine/Orc/...' file not found
#   20, 21, 22   -> compiles
#   23 and above -> no template named 'CWrapperFunctionResult' (renamed CWrapperFunctionBuffer)
set(LLVM_MIN_MAJOR 20)
set(LLVM_MAX_MAJOR 22)
option(CATALYST_EXECUTOR_ALLOW_SYSTEM_LLVM
       "Also consider an LLVM installed in the sysroot, not just Catalyst's own checkout" OFF)

# The generated toolchain sets this; the fallback keeps standalone `-DCATALYST_SRC` working.
if(NOT CROSSBUILD_CMAKE_DIR)
    set(CROSSBUILD_CMAKE_DIR "${CMAKE_CURRENT_LIST_DIR}/../../cmake")
endif()
list(APPEND CMAKE_MODULE_PATH "${CROSSBUILD_CMAKE_DIR}")
include(CrossbuildFindLLVM)

if(NOT LLVM_DIR)
    crossbuild_find_llvm(LLVM_DIR
        MIN_MAJOR ${LLVM_MIN_MAJOR}
        MAX_MAJOR ${LLVM_MAX_MAJOR}
        ALLOW_SYSTEM ${CATALYST_EXECUTOR_ALLOW_SYSTEM_LLVM}
        PINNED_GLOBS
            "${CATALYST_SRC}/mlir/llvm-project/*build*/lib/cmake/llvm"
            "${CATALYST_SRC}/mlir/llvm-project/*build*/lib64/cmake/llvm"
        SYSTEM_GLOBS
            "${CMAKE_SYSROOT}/usr/lib/llvm-*/lib/cmake/llvm"
            "${CMAKE_SYSROOT}/usr/lib64/llvm-*/lib/cmake/llvm"
            "${CMAKE_SYSROOT}/usr/lib/*/cmake/llvm"
            "${CMAKE_SYSROOT}/usr/lib/cmake/llvm"
            "${CMAKE_SYSROOT}/usr/lib64/cmake/llvm")
endif()

if(NOT LLVM_DIR)
    set(_hint "")
    if(LLVM_DIR_REJECTED)
        set(_hint "\nFound, but not usable:\n    ${LLVM_DIR_REJECTED}\n")
    endif()
    if(NOT CATALYST_EXECUTOR_ALLOW_SYSTEM_LLVM)
        string(APPEND _hint
               "\nTo consider an LLVM from the sysroot as well, configure with "
               "-DCATALYST_EXECUTOR_ALLOW_SYSTEM_LLVM=ON — note that a system LLVM outside "
               "${LLVM_MIN_MAJOR}-${LLVM_MAX_MAJOR} will not compile this source.")
    endif()
    message(FATAL_ERROR
        "No LLVM for this target under '${CATALYST_SRC}/mlir/llvm-project'.${_hint}\n"
        "Build the one Catalyst pins:\n"
        "    make catalyst-llvm TARGET=<target> CATALYST=${CATALYST_SRC}\n"
        "It is found automatically afterwards. Or pass -DLLVM_DIR=<dir with LLVMConfig.cmake>.")
endif()

find_package(LLVM CONFIG REQUIRED)
message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION} (${LLVM_DIR})")

# Checked again here, because an explicit -DLLVM_DIR skips the search above.
if(LLVM_VERSION_MAJOR LESS LLVM_MIN_MAJOR OR LLVM_VERSION_MAJOR GREATER LLVM_MAX_MAJOR)
    message(FATAL_ERROR
        "LLVM ${LLVM_VERSION_MAJOR} at '${LLVM_DIR}' is outside the range this source compiles "
        "against (${LLVM_MIN_MAJOR}-${LLVM_MAX_MAJOR}). Below ${LLVM_MIN_MAJOR} the ORC headers "
        "it includes do not exist yet; above ${LLVM_MAX_MAJOR}, CWrapperFunctionResult was "
        "renamed to CWrapperFunctionBuffer.")
endif()

# Match how LLVM was built, or every translation unit disagrees with its headers.
set(_match_flags)
if(NOT LLVM_ENABLE_RTTI)
    list(APPEND _match_flags -fno-rtti)
endif()
if(DEFINED LLVM_ENABLE_EH AND NOT LLVM_ENABLE_EH)
    list(APPEND _match_flags -fno-exceptions)
endif()

llvm_map_components_to_libnames(_executor_libs
    orcjit orctargetprocess orcshared support
)

add_executable(catalyst-executor "${EXECUTOR_SRC}")

target_include_directories(catalyst-executor SYSTEM PRIVATE ${LLVM_INCLUDE_DIRS})

separate_arguments(_llvm_defs NATIVE_COMMAND "${LLVM_DEFINITIONS}")
target_compile_definitions(catalyst-executor PRIVATE ${_llvm_defs})
target_compile_options(catalyst-executor PRIVATE
    -Wall -Wextra
    $<$<COMPILE_LANGUAGE:CXX>:${_match_flags}>
)

target_link_libraries(catalyst-executor PRIVATE
    ${_executor_libs}
    pthread
    ${CMAKE_DL_LIBS}
)

# The JIT resolves symbols in this process by name, so its own symbols must be dynamic.
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(catalyst-executor PRIVATE -Wl,--export-dynamic)
elseif(APPLE)
    target_link_options(catalyst-executor PRIVATE -Wl,-export_dynamic)
endif()

install(TARGETS catalyst-executor RUNTIME DESTINATION bin)
