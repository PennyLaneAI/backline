cmake_minimum_required(VERSION 3.20)
# C as well as CXX, even though nothing here compiles a .c file. LLVMConfig.cmake pulls in
# its own dependency checks (FindTerminfo, FindFFI) which call check_c_source_compiles, and
# with only CXX enabled those abort the configure with
#     check_source_compiles: C: needs to be enabled before use.
# pointing inside LLVM's own modules rather than at this line.
project(catalyst_executor C CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# The executor source is owned by Catalyst; this project only cross-builds it, so that a target
# binary and the host build always come from one implementation.
set(CATALYST_SRC "" CACHE PATH "Path to a Catalyst checkout providing the executor source")
set(EXECUTOR_SRC "${CATALYST_SRC}/runtime/lib/executor/executor.cpp")
if(NOT CATALYST_SRC OR NOT EXISTS "${EXECUTOR_SRC}")
    message(FATAL_ERROR
        "CATALYST_SRC must point at a Catalyst checkout containing "
        "runtime/lib/executor/executor.cpp (looked for '${EXECUTOR_SRC}'). "
        "Pass -DCATALYST_SRC=/path/to/catalyst, or build via the Makefile with CATALYST=...")
endif()

# ── which LLVM to link ───────────────────────────────────────────────────────
#
# The version window this source actually compiles against, measured against
# runtime/lib/executor/executor.cpp rather than guessed:
#   19 and below -> fatal error: 'llvm/ExecutionEngine/Orc/...' file not found
#   20, 21, 22   -> compiles
#   23 and above -> no template named 'CWrapperFunctionResult' (renamed CWrapperFunctionBuffer)
# Declared before use so the messages below can quote it.
set(LLVM_MIN_MAJOR 20)
set(LLVM_MAX_MAJOR 22)
#
# Debian and Ubuntu ship no versionless /usr/lib/cmake/llvm — each toolchain lives in
# /usr/lib/llvm-<N>/lib/cmake/llvm — so find_package(LLVM CONFIG) has nothing to find
# unless told where to look, and reports "Could not find a package configuration file
# provided by LLVM" on a machine that plainly has LLVM installed.
#
# WHERE to look depends on whether this is a cross build, and getting that wrong produces
# two very different confusing failures:
#
#   cross  -> the SYSROOT, always. This binary runs ON the target and JITs code there, so
#             it must link the target's LLVM. Catalyst's in-tree build is a HOST build
#             (x86-64 archives), and linking those into an aarch64 executable fails deep in
#             lld with "incompatible with elf64-littleaarch64".
#   native -> Catalyst's own checkout first. It is the version the source is written
#             against, whereas the newest system LLVM may not be: LLVM 23 renamed
#             CWrapperFunctionResult to CWrapperFunctionBuffer, which surfaces as errors in
#             Catalyst's source and reads like a bad checkout.
#
# An explicit -DLLVM_DIR always wins, and is how you point at a target-architecture build
# of Catalyst's llvm-project once you have one.
# NOT keyed on CMAKE_CROSSCOMPILING: the generated toolchain sets that TRUE for every
# target including the native one (it must, or CMake tries to RUN test binaries). The
# question here is narrower and answerable — can archives built for the build host be
# linked into this target at all? That is purely an architecture comparison.
# Any build directory in the Catalyst tree, plus the sysroot's own LLVM. Which of them is
# ACCEPTABLE is decided below by reading each one, not by the pattern that found it — a
# directory name is a guess, and this one guessed wrong: `build-aarch64` sorts BEFORE `build/`
# ('-' is 0x2D, '/' is 0x2F), so a name-ordered search handed the x86-64 native build the
# aarch64 archives and lld reported "is incompatible with elf64-x86-64" for every object.
set(_llvm_search_dirs
    "${CATALYST_SRC}/mlir/llvm-project/*build*/lib/cmake/llvm"
    "${CATALYST_SRC}/mlir/llvm-project/*build*/lib64/cmake/llvm"
    "${CMAKE_SYSROOT}/usr/lib/llvm-*/lib/cmake/llvm"
    "${CMAKE_SYSROOT}/usr/lib/*/cmake/llvm"
    "${CMAKE_SYSROOT}/usr/lib/cmake/llvm")

# Screen every candidate on the two things that actually decide whether it can be linked, both
# read out of its own LLVMConfig.cmake rather than inferred from where it sits:
#
#   ARCHITECTURE — LLVM_HOST_TRIPLE is the machine that LLVM was built to RUN on, which is
#                  what has to match this target. Wrong arch is a link error per object.
#   VERSION      — the ORC C-API window this source compiles against (see above).
if(NOT LLVM_DIR)
    set(_llvm_rejected)
    set(_best_major 0)
    # Alias the spellings that mean one machine, so a config saying arm64 or amd64 is not
    # rejected against a target saying aarch64 or x86_64.
    set(_want_arch "${CMAKE_SYSTEM_PROCESSOR}")
    if(_want_arch STREQUAL "arm64")
        set(_want_arch "aarch64")
    elseif(_want_arch STREQUAL "amd64")
        set(_want_arch "x86_64")
    endif()

    foreach(_pattern IN LISTS _llvm_search_dirs)
        file(GLOB _found "${_pattern}")
        foreach(_cand IN LISTS _found)
            if(NOT EXISTS "${_cand}/LLVMConfig.cmake")
                continue()
            endif()
            file(STRINGS "${_cand}/LLVMConfig.cmake" _vline
                 REGEX "^set\\(LLVM_VERSION_MAJOR [0-9]+\\)" LIMIT_COUNT 1)
            string(REGEX MATCH "[0-9]+" _cmajor "${_vline}")
            if(NOT _cmajor)
                continue()
            endif()

            # LLVM_HOST_TRIPLE first; a distro package may only carry the default triple.
            file(STRINGS "${_cand}/LLVMConfig.cmake" _tline
                 REGEX "^set\\(LLVM_(HOST_TRIPLE|DEFAULT_TARGET_TRIPLE) " LIMIT_COUNT 1)
            string(REGEX MATCH "\"[^\"]+\"|[A-Za-z0-9_.-]+\\)$" _traw "${_tline}")
            string(REGEX REPLACE "[\")]" "" _traw "${_traw}")
            string(REGEX MATCH "^[A-Za-z0-9_]+" _carch "${_traw}")
            if(_carch STREQUAL "arm64")
                set(_carch "aarch64")
            elseif(_carch STREQUAL "amd64")
                set(_carch "x86_64")
            endif()

            if(_carch AND NOT _carch STREQUAL _want_arch)
                list(APPEND _llvm_rejected "${_cand}\n        LLVM ${_cmajor}, built for ${_carch}, need ${_want_arch}")
            elseif(_cmajor LESS LLVM_MIN_MAJOR OR _cmajor GREATER LLVM_MAX_MAJOR)
                list(APPEND _llvm_rejected "${_cand}\n        LLVM ${_cmajor}, outside the supported ${LLVM_MIN_MAJOR}-${LLVM_MAX_MAJOR}")
            elseif(_cmajor GREATER _best_major)
                set(_best_major ${_cmajor})
                set(LLVM_DIR "${_cand}")
            endif()
        endforeach()
        # Earlier patterns outrank later ones: Catalyst's own checkout is preferred over a
        # distro LLVM in the sysroot even when the distro one is newer, because the checkout is
        # the version the host side of the ORC connection is built from.
        if(LLVM_DIR)
            break()
        endif()
    endforeach()
endif()

# Report what was found and rejected, so "no LLVM" and "only unusable LLVMs" are
# distinguishable. The second is the common case on a stock distro and needs a different fix.
if(NOT LLVM_DIR AND _llvm_rejected)
    string(REPLACE ";" "\n    " _rejected_txt "${_llvm_rejected}")
    message(FATAL_ERROR
        "Found LLVM, but no usable version (need ${LLVM_MIN_MAJOR}-${LLVM_MAX_MAJOR}):\n"
        "    ${_rejected_txt}\n"
        "Below ${LLVM_MIN_MAJOR} the ORC headers this source includes do not exist yet; from 23 "
        "on, CWrapperFunctionResult was renamed to CWrapperFunctionBuffer. Install a supported "
        "llvm-<N>-dev where the artifact's libraries come from (the sysroot for a cross build), "
        "or pass -DLLVM_DIR.")
endif()

if(NOT LLVM_DIR)
    # Name the command that produces what is missing. An error that describes the required
    # artifact without saying that this tree has a target which builds it is a dead end for
    # anyone who has not read docs/05-troubleshooting.md.
    if(CMAKE_SYSTEM_PROCESSOR STREQUAL CMAKE_HOST_SYSTEM_PROCESSOR)
        message(FATAL_ERROR
            "No usable LLVM found under '${CATALYST_SRC}/mlir/llvm-project' or in the sysroot.\n"
            "Build the LLVM Catalyst pins:\n"
            "    make catalyst-llvm TARGET=<target> CATALYST=${CATALYST_SRC}\n"
            "or see catalyst/mlir/Makefile, or pass -DLLVM_DIR=<dir containing LLVMConfig.cmake>.")
    else()
        message(FATAL_ERROR
            "No ${CMAKE_SYSTEM_PROCESSOR} LLVM found in the sysroot '${CMAKE_SYSROOT}'.\n"
            "A cross build must link the TARGET's LLVM: Catalyst's in-tree build is for the "
            "build host and cannot be linked into a ${CMAKE_SYSTEM_PROCESSOR} binary.\n"
            "Cross-build the LLVM Catalyst pins — this is what that target is for:\n"
            "    make catalyst-llvm TARGET=<target> CATALYST=${CATALYST_SRC}\n"
            "It is found automatically afterwards. Alternatives: install llvm-dev "
            "(${LLVM_MIN_MAJOR}-${LLVM_MAX_MAJOR}) on the target and re-fetch the sysroot, or "
            "pass -DLLVM_DIR at an existing ${CMAKE_SYSTEM_PROCESSOR} build.")
    endif()
endif()

message(STATUS "LLVM_DIR: ${LLVM_DIR}")
find_package(LLVM CONFIG REQUIRED)
message(STATUS "Found LLVM ${LLVM_PACKAGE_VERSION} (${LLVM_DIR})")

# Fail on a version mismatch HERE, naming the window, rather than letting it land as
# incomprehensible errors inside Catalyst's source. Both ends are real and measured against
# runtime/lib/executor/executor.cpp:
#   < 20  ->  fatal error: 'llvm/ExecutionEngine/Orc/...' file not found (header added in 20)
#   >= 23 ->  no template named 'CWrapperFunctionResult' (renamed to CWrapperFunctionBuffer)
if(LLVM_VERSION_MAJOR LESS LLVM_MIN_MAJOR OR LLVM_VERSION_MAJOR GREATER LLVM_MAX_MAJOR)
    message(FATAL_ERROR
        "LLVM ${LLVM_VERSION_MAJOR} at '${LLVM_DIR}' is outside the range this source "
        "compiles against (${LLVM_MIN_MAJOR}-${LLVM_MAX_MAJOR}).\n"
        "Below ${LLVM_MIN_MAJOR} the ORC headers it includes do not exist yet; from 23 on, "
        "CWrapperFunctionResult was renamed to CWrapperFunctionBuffer. Install a supported "
        "llvm-<N>-dev in the sysroot, or pass -DLLVM_DIR at one.")
endif()
message(STATUS "  default target triple: ${LLVM_DEFAULT_TARGET_TRIPLE}")

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

target_include_directories(catalyst-executor SYSTEM PRIVATE
    ${LLVM_INCLUDE_DIRS}
)

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

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(catalyst-executor PRIVATE -Wl,--export-dynamic)
elseif(APPLE)
    target_link_options(catalyst-executor PRIVATE -Wl,-export_dynamic)
endif()

install(TARGETS catalyst-executor RUNTIME DESTINATION bin)
