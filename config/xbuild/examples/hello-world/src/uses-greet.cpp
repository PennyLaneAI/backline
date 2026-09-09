// Links against libgreet.so by dependency NAME, not by path. Proves the
// dependency resolution in mk/rules.mk produces a working link and a working
// runtime lookup.
#include <cstdio>
extern "C" const char* crossbuild_greeting();
int main() {
    std::printf("%s\n", crossbuild_greeting());
    return 0;
}
