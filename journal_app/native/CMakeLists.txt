# native/CMakeLists.txt
#
# Build libfhe_wrapper.so — a shared library that embeds Python and wraps
# concrete-ml's FHEModelClient.
#
# Usage (standalone):
#   mkdir build && cd build
#   cmake .. -DCMAKE_BUILD_TYPE=Release
#   make
#
# Flutter linux integration:
#   The top-level linux/CMakeLists.txt adds this directory via
#   add_subdirectory(../native fhe_native).  The install() rule copies the
#   library to the bundle's lib/ directory alongside the app binary.
#
# Python environment:
#   By default CMake will locate the active Python 3 installation.  To build
#   against the project's venv (which contains concrete-ml) pass:
#       -DPython3_ROOT_DIR=/path/to/fhe_client/.venv
#   or set FHE_PYTHON_PREFIX in the environment before running cmake.

cmake_minimum_required(VERSION 3.14)
project(fhe_native CXX)

# ── Honour env-var override for venv Python ──────────────────────────────────
if(DEFINED ENV{FHE_PYTHON_PREFIX} AND NOT DEFINED Python3_ROOT_DIR)
  set(Python3_ROOT_DIR "$ENV{FHE_PYTHON_PREFIX}")
endif()

# ── Find Python 3 (Interpreter + Development headers + libraries) ─────────────
find_package(Python3 REQUIRED COMPONENTS Interpreter Development)

# ── Build shared library ──────────────────────────────────────────────────────
add_library(fhe_wrapper SHARED fhe_wrapper.cpp)

target_compile_features(fhe_wrapper PRIVATE cxx_std_14)
set_target_properties(fhe_wrapper PROPERTIES
  PREFIX ""                     # produce fhe_wrapper.so, not libfhe_wrapper.so ...
  OUTPUT_NAME "fhe_wrapper"     # ... wait, flutter expects libfhe_wrapper.so
  POSITION_INDEPENDENT_CODE ON
)
# Override prefix to get libfhe_wrapper.so as Dart FFI expects:
set_target_properties(fhe_wrapper PROPERTIES PREFIX "lib")

target_include_directories(fhe_wrapper PRIVATE ${Python3_INCLUDE_DIRS})
target_link_libraries(fhe_wrapper PRIVATE ${Python3_LIBRARIES})

# ── Install ───────────────────────────────────────────────────────────────────
# When built as part of the Flutter linux bundle the library lands in lib/
# alongside the app binary.
install(TARGETS fhe_wrapper
  LIBRARY DESTINATION "${CMAKE_INSTALL_PREFIX}"
)

# Bundle the Python helper script next to the library so the C wrapper can
# find it at a predictable relative path.  (The Dart FheClient also extracts
# it from Flutter assets at runtime, so this is belt-and-suspenders.)
install(FILES fhe_helper.py
  DESTINATION "${CMAKE_INSTALL_PREFIX}"
)
