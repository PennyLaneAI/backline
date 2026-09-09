// A shared library used by the test suite to exercise:
//   * COMPONENT_KIND=shared-library and -soname handling
//   * COMPONENT_DEPENDS resolution (hello-linked links against this by NAME)
//   * RPATH=$ORIGIN, i.e. that a deployed bundle resolves siblings with no
//     LD_LIBRARY_PATH
#include <string>
extern "C" const char* crossbuild_greeting() {
    static std::string s = "greeting from a shared library beside me";
    return s.c_str();
}
