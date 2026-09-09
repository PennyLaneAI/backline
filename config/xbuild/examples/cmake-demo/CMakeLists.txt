# A minimal CMake project used to exercise COMPONENT_KIND=cmake-project.
#
# The point of this fixture is to prove that the GENERATED toolchain file
# (tools/gen-cmake-toolchain.sh) actually drives cmake with the same target
# settings the direct-compiler path uses — the duplication the original design
# maintained by hand under a "KEEP IN SYNC" comment.
cmake_minimum_required(VERSION 3.16)
project(cmake_demo CXX)
# 20 to match the tree's floor, and REQUIRED so a toolchain that cannot provide it fails
# here instead of silently compiling as C++17 — which is how a project ends up disagreeing
# with the -std flag the generated toolchain file passes in.
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
add_executable(cmake-demo main.cpp)
install(TARGETS cmake-demo RUNTIME DESTINATION bin)
