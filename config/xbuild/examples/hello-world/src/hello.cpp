// A deliberately tiny program used by `make quickstart` and by the test suite.
//
// Its job is to be the smallest thing that still exercises the whole pipeline:
// it is C++ (so it pulls in libstdc++ and therefore has a real ABI surface),
// it prints its own build-time target triple (so you can see, at runtime, which
// target it was built for), and it has no dependencies beyond the standard
// library.
//
// If this builds and verifies for a new target, the toolchain, the sysroot and the
// flag derivation are all correct. If it does not, nothing larger will, and you
// have a five-line reproduction instead of a large one.
#include <cstdio>
#include <string>

// Set by the build from the target description, so the binary can report what it
// was built for. Useful when a bundle has been copied around and you want to know
// what you are holding.
#ifndef BUILD_TARGET_TRIPLE
#define BUILD_TARGET_TRIPLE "unknown"
#endif
#ifndef BUILD_TARGET_NAME
#define BUILD_TARGET_NAME "unknown"
#endif

int main() {
    // std::string forces a real libstdc++ dependency; without it the compiler
    // could optimise this into a pure-libc binary and the C++ ABI checks would
    // have nothing to look at.
    std::string who = BUILD_TARGET_NAME;
    std::printf("hello from crossbuild\n");
    std::printf("  built for target : %s\n", who.c_str());
    std::printf("  triple           : %s\n", BUILD_TARGET_TRIPLE);
    return 0;
}
