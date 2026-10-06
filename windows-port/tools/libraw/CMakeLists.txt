# Builds LibRaw as a static library (and optionally the DLL) for compositor_win.
#
# The LibRaw tarball has no CMake support of its own - upstream moved that to a separate repository -
# so this file lists nothing by hand: it globs the official source tree, sets the defines LibRaw's own
# MSVC makefile sets, and hands back a plain static library named libraw_r.
#
#   cmake -S tools/libraw -B <build> -G "Visual Studio 17 2022" -A x64 \
#         -DLIBRAW_ROOT=<LibRaw-0.21.4> -DLIBRAW_JPEG_SRC=<libjpeg-turbo-3.1.2> \
#         -DLIBRAW_JPEG_BUILD=<libjpeg build dir> -DLIBRAW_JPEG_LIB=<jpeg.lib> -DLIBRAW_BUILD_SHARED=OFF
#
# LIBRAW_BUILD_SHARED=ON produces the DLL instead, which is the build whose redistribution is easiest
# to reason about for a closed-source product (see crates/comp-raw/NOTES.md).

cmake_minimum_required(VERSION 3.15)
project(compositor_libraw CXX C)

if(NOT LIBRAW_ROOT)
  message(FATAL_ERROR "pass -DLIBRAW_ROOT=<unpacked LibRaw source directory>")
endif()

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release)
endif()

if(MSVC)
  # LibRaw throws and catches its own exceptions, so /EHsc is required rather than optional.
  add_compile_options(/EHsc /MP /bigobj)
  add_compile_definitions(_CRT_SECURE_NO_WARNINGS _USE_MATH_DEFINES WIN32 NOMINMAX)
endif()

# Everything LibRaw ships lives under src/, including the decoders, the demosaic packs and the X3F
# parser. integration/ is guarded by its own USE_RAWSPEED / USE_DNGSDK defines, so it compiles to
# nothing here.
#
# The glob is deliberately not CONFIGURE_DEPENDS: that option writes the source path into a
# VerifyGlobs.cmake script, and a Windows path with backslashes stops CMake reading its own file
# ("Invalid character escape '\C'"). The path is normalized first for the same reason.
file(TO_CMAKE_PATH "${LIBRAW_ROOT}" LIBRAW_ROOT_CMAKE)
file(GLOB_RECURSE LIBRAW_SOURCES "${LIBRAW_ROOT_CMAKE}/src/*.cpp")
# *_ph.cpp are placeholders ("to build LibRaw w/o postprocessing tools") that reimplement the same
# symbols as the real sources; compiling both gives multiply defined symbols at link time.
list(FILTER LIBRAW_SOURCES EXCLUDE REGEX "_ph\\.cpp$")
list(LENGTH LIBRAW_SOURCES LIBRAW_SOURCE_COUNT)
if(LIBRAW_SOURCE_COUNT LESS 50)
  message(FATAL_ERROR "only ${LIBRAW_SOURCE_COUNT} sources found under ${LIBRAW_ROOT}/src")
endif()
message(STATUS "LibRaw: ${LIBRAW_SOURCE_COUNT} source files from ${LIBRAW_ROOT}")

function(libraw_common target)
  target_include_directories(${target} PUBLIC "${LIBRAW_ROOT_CMAKE}" PRIVATE "${LIBRAW_ROOT_CMAKE}/src")
  if(LIBRAW_JPEG_SRC)
    # DNG compression 34892 (lossy JPEG) is only decoded when LibRaw is built with libjpeg.
    target_compile_definitions(${target} PRIVATE USE_JPEG)
    target_include_directories(${target} PRIVATE "${LIBRAW_JPEG_SRC}")
  endif()
  if(LIBRAW_JPEG_BUILD)
    target_include_directories(${target} PRIVATE "${LIBRAW_JPEG_BUILD}")
  endif()
endfunction()

# DllDef is only meaningful with LIBRAW_WIN32_DLLDEFS; LIBRAW_NODLL makes it empty for the static
# library and LIBRAW_BUILDLIB makes it __declspec(dllexport) for the DLL. These are the defines
# LibRaw's own Makefile.msvc passes, and getting them wrong is what makes a DLL build fail with
# "definition of dllimport static data member not allowed".
add_library(rawr STATIC ${LIBRAW_SOURCES})
libraw_common(rawr)
target_compile_definitions(rawr PRIVATE LIBRAW_WIN32_DLLDEFS LIBRAW_NODLL)
set_target_properties(rawr PROPERTIES OUTPUT_NAME libraw_r)

# LibRaw's own command line tools, for telling an upstream decoder bug apart from a mistake in the
# way compositor calls it: run the same file through dcraw_emu and see whether it dies the same way.
if(LIBRAW_BUILD_TOOLS)
  foreach(tool dcraw_emu raw-identify)
    add_executable(${tool} "${LIBRAW_ROOT_CMAKE}/samples/${tool}.cpp")
    libraw_common(${tool})
    target_compile_definitions(${tool} PRIVATE LIBRAW_WIN32_DLLDEFS LIBRAW_NODLL)
    target_link_libraries(${tool} PRIVATE rawr)
    if(LIBRAW_JPEG_LIB)
      target_link_libraries(${tool} PRIVATE "${LIBRAW_JPEG_LIB}")
    endif()
  endforeach()
endif()

if(LIBRAW_BUILD_SHARED)
  add_library(rawr_shared SHARED ${LIBRAW_SOURCES})
  libraw_common(rawr_shared)
  target_compile_definitions(rawr_shared PRIVATE LIBRAW_WIN32_DLLDEFS LIBRAW_BUILDLIB)
  set_target_properties(rawr_shared PROPERTIES OUTPUT_NAME raw)
  if(LIBRAW_JPEG_LIB)
    target_link_libraries(rawr_shared PRIVATE "${LIBRAW_JPEG_LIB}")
  endif()
endif()
