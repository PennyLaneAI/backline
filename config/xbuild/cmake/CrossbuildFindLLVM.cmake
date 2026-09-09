# CrossbuildFindLLVM.cmake — pick the LLVM a target can link, pinned checkout first.
#
# POLICY: a project that links LLVM is written against one LLVM, so the copy its own checkout
# pins is authoritative. PINNED_GLOBS are searched by default; SYSTEM_GLOBS only when the caller
# passes ALLOW_SYSTEM TRUE. "Some LLVM of roughly the right version" gives link errors per object
# (wrong architecture) or compile errors inside the project's headers (moved C-API).
#
# USAGE
#   include(CrossbuildFindLLVM)
#   crossbuild_find_llvm(LLVM_DIR
#       MIN_MAJOR 20 MAX_MAJOR 22
#       PINNED_GLOBS "${SRC}/mlir/llvm-project/*build*/lib/cmake/llvm"
#       SYSTEM_GLOBS "${CMAKE_SYSROOT}/usr/lib/llvm-*/lib/cmake/llvm"
#       ALLOW_SYSTEM ${SOME_OPTION})
#
# Sets <out-var> to the chosen directory or empty, and <out-var>_REJECTED to what was found and
# why each candidate was refused. Architectures compare through tools/arch-table.sh, which owns
# the fact that aarch64 and arm64 are one machine.

set(_crossbuild_arch_table "${CMAKE_CURRENT_LIST_DIR}/../tools/arch-table.sh")

# Canonical name, or the input unchanged when the table cannot answer.
function(crossbuild_canon_arch _arch _out)
    set(${_out} "${_arch}" PARENT_SCOPE)
    if(NOT _arch)
        return()
    endif()
    execute_process(COMMAND "${_crossbuild_arch_table}" deb-arch "${_arch}"
                    OUTPUT_VARIABLE _deb ERROR_QUIET OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(_deb)
        set(${_out} "${_deb}" PARENT_SCOPE)
    endif()
endfunction()

# The two facts that decide linkability: the version, and LLVM_HOST_TRIPLE (the machine LLVM
# itself runs on). Empty major means unusable.
function(crossbuild_llvm_probe _dir _out_major _out_arch)
    set(${_out_major} "" PARENT_SCOPE)
    set(${_out_arch} "" PARENT_SCOPE)
    if(NOT EXISTS "${_dir}/LLVMConfig.cmake")
        return()
    endif()
    # One read for both; they sit at opposite ends of the file.
    file(STRINGS "${_dir}/LLVMConfig.cmake" _lines
         REGEX "^set\\(LLVM_(VERSION_MAJOR|HOST_TRIPLE|DEFAULT_TARGET_TRIPLE) ")
    foreach(_l IN LISTS _lines)
        if(_l MATCHES "^set\\(LLVM_VERSION_MAJOR ([0-9]+)\\)")
            set(_major "${CMAKE_MATCH_1}")
        elseif(NOT DEFINED _traw AND _l MATCHES "^set\\(LLVM_(HOST_TRIPLE|DEFAULT_TARGET_TRIPLE) +\"?([^\")]+)")
            set(_traw "${CMAKE_MATCH_2}")
        endif()
    endforeach()
    if(NOT DEFINED _major)
        return()
    endif()
    string(REGEX MATCH "^[A-Za-z0-9_]+" _arch "${_traw}")
    crossbuild_canon_arch("${_arch}" _arch)
    set(${_out_major} "${_major}" PARENT_SCOPE)
    set(${_out_arch} "${_arch}" PARENT_SCOPE)
endfunction()

function(crossbuild_find_llvm _out_var)
    cmake_parse_arguments(A "" "MIN_MAJOR;MAX_MAJOR;TARGET_ARCH;ALLOW_SYSTEM"
                            "PINNED_GLOBS;SYSTEM_GLOBS" ${ARGN})
    if(NOT A_MIN_MAJOR OR NOT A_MAX_MAJOR)
        message(FATAL_ERROR "crossbuild_find_llvm: MIN_MAJOR and MAX_MAJOR are required")
    endif()

    # CROSSBUILD_TARGET_ARCH comes from the generated toolchain and is already canonical.
    if(A_TARGET_ARCH)
        set(_want "${A_TARGET_ARCH}")
    elseif(DEFINED CROSSBUILD_TARGET_ARCH)
        set(_want "${CROSSBUILD_TARGET_ARCH}")
    else()
        set(_want "${CMAKE_SYSTEM_PROCESSOR}")
    endif()
    crossbuild_canon_arch("${_want}" _want)

    set(_globs ${A_PINNED_GLOBS})
    if(A_ALLOW_SYSTEM)
        list(APPEND _globs ${A_SYSTEM_GLOBS})
    endif()

    set(_rejected)
    set(_best 0)
    set(_found "")
    foreach(_pattern IN LISTS _globs)
        file(GLOB _cands "${_pattern}")
        foreach(_cand IN LISTS _cands)
            crossbuild_llvm_probe("${_cand}" _major _arch)
            if(NOT _major)
                continue()
            endif()
            if(_arch AND NOT _arch STREQUAL _want)
                list(APPEND _rejected "${_cand} — LLVM ${_major}, built for ${_arch}, need ${_want}")
            elseif(_major LESS A_MIN_MAJOR OR _major GREATER A_MAX_MAJOR)
                list(APPEND _rejected "${_cand} — LLVM ${_major}, outside ${A_MIN_MAJOR}-${A_MAX_MAJOR}")
            elseif(_major GREATER _best)
                set(_best ${_major})
                set(_found "${_cand}")
                # Nothing later can beat the top of the window, so stop reading configs.
                if(_best EQUAL A_MAX_MAJOR)
                    break()
                endif()
            endif()
        endforeach()
        # Earlier globs outrank later ones: a pinned checkout beats a newer system install.
        if(_found)
            break()
        endif()
    endforeach()

    list(JOIN _rejected "\n    " _rejected_txt)
    set(${_out_var} "${_found}" PARENT_SCOPE)
    set(${_out_var}_REJECTED "${_rejected_txt}" PARENT_SCOPE)
endfunction()
