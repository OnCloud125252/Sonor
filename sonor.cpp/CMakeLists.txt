cmake_minimum_required(VERSION 3.5) # for add_link_options and implicit target directories.
project("sonor.cpp" C CXX)
project("sonor.cpp" VERSION 1.8.4)
include(CheckIncludeFileCXX)

set(SOVERSION 1)

#set(CMAKE_WARN_DEPRECATED YES)
set(CMAKE_WARN_UNUSED_CLI YES)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if (NOT XCODE AND NOT MSVC AND NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS "Debug" "Release" "MinSizeRel" "RelWithDebInfo")
endif()

# Add path to modules
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake/")

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)

if (CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    set(SONOR_STANDALONE ON)

    include(git-vars)

    # configure project version
    configure_file(${CMAKE_SOURCE_DIR}/bindings/javascript/package-tmpl.json ${CMAKE_SOURCE_DIR}/bindings/javascript/package.json @ONLY)
else()
    set(SONOR_STANDALONE OFF)
endif()

if (EMSCRIPTEN)
    set(BUILD_SHARED_LIBS_DEFAULT OFF)

    set(CMAKE_CXX_STANDARD 17)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)

    option(SONOR_WASM_SINGLE_FILE "sonor: embed WASM inside the generated sonor.js" ON)

    # TODO: without these, we get the following error:
    #       wasm-ld: error: --shared-memory is disallowed by sonor.cpp.o because it was not compiled with 'atomics' or 'bulk-memory' features.
    set(CMAKE_C_FLAGS   "${CMAKE_C_FLAGS}   -pthread")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")

    set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -s TOTAL_STACK=5242880")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -s TOTAL_STACK=5242880")

    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wno-deprecated")
else()
    if (MINGW)
        set(BUILD_SHARED_LIBS_DEFAULT OFF)
    else()
        set(BUILD_SHARED_LIBS_DEFAULT ON)
    endif()
endif()

option(BUILD_SHARED_LIBS "build shared libraries" ${BUILD_SHARED_LIBS_DEFAULT})

#
# option list
#

# debug
option(SONOR_ALL_WARNINGS           "sonor: enable all compiler warnings"                   ON)
option(SONOR_ALL_WARNINGS_3RD_PARTY "sonor: enable all compiler warnings in 3rd party libs" OFF)

# build
option(SONOR_FATAL_WARNINGS  "sonor: enable -Werror flag"               OFF)
option(SONOR_USE_SYSTEM_GGML "sonor: use system-installed GGML library" OFF)

# sanitizers
option(SONOR_SANITIZE_THREAD    "sonor: enable thread sanitizer"    OFF)
option(SONOR_SANITIZE_ADDRESS   "sonor: enable address sanitizer"   OFF)
option(SONOR_SANITIZE_UNDEFINED "sonor: enable undefined sanitizer" OFF)

# extra artifacts
option(SONOR_BUILD_TESTS    "sonor: build tests"          ${SONOR_STANDALONE})
option(SONOR_BUILD_EXAMPLES "sonor: build examples"       ${SONOR_STANDALONE})
option(SONOR_BUILD_SERVER   "sonor: build server example" ${SONOR_STANDALONE})

# 3rd party libs
option(SONOR_CURL "sonor: use libcurl to download model from an URL" OFF)
option(SONOR_SDL2 "sonor: support for libSDL2" OFF)

if (CMAKE_SYSTEM_NAME MATCHES "Linux")
    option(SONOR_FFMPEG "sonor: support building and linking with ffmpeg libs (avcodec, swresample, ...)" OFF)
endif()

option(SONOR_COREML                "sonor: enable Core ML framework"  OFF)
option(SONOR_COREML_ALLOW_FALLBACK "sonor: allow non-CoreML fallback" OFF)
option(SONOR_OPENVINO              "sonor: support for OpenVINO"      OFF)

# Required for relocatable CMake package
include(${CMAKE_CURRENT_SOURCE_DIR}/cmake/build-info.cmake)

# override ggml options
set(GGML_SANITIZE_THREAD    ${SONOR_SANITIZE_THREAD})
set(GGML_SANITIZE_ADDRESS   ${SONOR_SANITIZE_ADDRESS})
set(GGML_SANITIZE_UNDEFINED ${SONOR_SANITIZE_UNDEFINED})
set(GGML_ALL_WARNINGS       ${SONOR_ALL_WARNINGS})
set(GGML_FATAL_WARNINGS     ${SONOR_FATAL_WARNINGS})

# transition helpers
function (sonor_option_depr TYPE OLD NEW)
    if (${OLD})
        message(${TYPE} "${OLD} is deprecated and will be removed in the future.\nUse ${NEW} instead\n")
        set(${NEW} ON)
    endif()
endfunction()

sonor_option_depr(FATAL_ERROR SONOR_CUBLAS              GGML_CUDA)
sonor_option_depr(WARNING     SONOR_CUDA                GGML_CUDA)
sonor_option_depr(WARNING     SONOR_KOMPUTE             GGML_KOMPUTE)
sonor_option_depr(WARNING     SONOR_METAL               GGML_METAL)
sonor_option_depr(WARNING     SONOR_METAL_EMBED_LIBRARY GGML_METAL_EMBED_LIBRARY)
sonor_option_depr(WARNING     SONOR_NATIVE              GGML_NATIVE)
sonor_option_depr(WARNING     SONOR_OPENMP              GGML_OPENMP)
sonor_option_depr(WARNING     SONOR_RPC                 GGML_RPC)
sonor_option_depr(WARNING     SONOR_SYCL                GGML_SYCL)
sonor_option_depr(WARNING     SONOR_SYCL_F16            GGML_SYCL_F16)
sonor_option_depr(WARNING     SONOR_CCACHE              GGML_CCACHE)

if (GGML_CUDA AND NOT MSVC)
    #GGML_CUDA enabled, add the necessary compile options -Wno-deprecated-gpu-targets
    add_compile_options(-Wno-deprecated-gpu-targets)
endif()

#
# build the library
#

if (NOT TARGET ggml)
    if (SONOR_USE_SYSTEM_GGML)
        find_package(ggml REQUIRED)
        if (NOT ggml_FOUND)
            message(FATAL_ERROR "System-installed GGML library not found.")
        endif()
        add_library(ggml ALIAS ggml::ggml)
    else()
        add_subdirectory(ggml)
        if(WIN32)
            # The following adds a _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR macro and is a workaround for
            # the Windows C++ standard library which does not support constexpr mutexes.
            # From the release notes://github.com/microsoft/STL/wiki/Changelog
            #  Disable constexpr mutex constructor on Windows
            #  Fixed mutex's constructor to be constexpr. #3824 #4000 #4339
            #  Note: Programs that aren't following the documented restrictions on binary compatibility may encounter
            #  null dereferences in mutex machinery. You must follow this rule:
            #  When you mix binaries built by different supported versions of the toolset, the Redistributable version
            #  must be at least as new as the latest toolset used by any app component.
            #  You can define _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR as an escape hatch.
            #
            # Specifically to sonor.cpp this would cause a crash when using the Java bindings.
            # resulting in a Invalid memory access error.
            target_compile_definitions(ggml-base PRIVATE _DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)
        endif()
    endif()
    # ... otherwise assume ggml is added by a parent CMakeLists.txt
endif()
add_subdirectory(src)

#
# install
#

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)

set(SONOR_BUILD_NUMBER        ${BUILD_NUMBER})
set(SONOR_BUILD_COMMIT        ${BUILD_COMMIT})
set(SONOR_INSTALL_VERSION     ${CMAKE_PROJECT_VERSION})

set(SONOR_INCLUDE_INSTALL_DIR ${CMAKE_INSTALL_INCLUDEDIR} CACHE PATH "Location of header  files")
set(SONOR_LIB_INSTALL_DIR     ${CMAKE_INSTALL_LIBDIR}     CACHE PATH "Location of library files")
set(SONOR_BIN_INSTALL_DIR     ${CMAKE_INSTALL_BINDIR}     CACHE PATH "Location of binary  files")

get_directory_property(SONOR_TRANSIENT_DEFINES COMPILE_DEFINITIONS)

set_target_properties(sonor PROPERTIES PUBLIC_HEADER ${CMAKE_CURRENT_SOURCE_DIR}/include/sonor.h)
install(TARGETS sonor LIBRARY PUBLIC_HEADER)

target_compile_definitions(sonor PRIVATE
    SONOR_VERSION="${PROJECT_VERSION}"
)

configure_package_config_file(
        ${CMAKE_CURRENT_SOURCE_DIR}/cmake/sonor-config.cmake.in
        ${CMAKE_CURRENT_BINARY_DIR}/sonor-config.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/sonor
    PATH_VARS
    SONOR_INCLUDE_INSTALL_DIR
    SONOR_LIB_INSTALL_DIR
    SONOR_BIN_INSTALL_DIR )

write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/sonor-version.cmake
    VERSION ${SONOR_INSTALL_VERSION}
    COMPATIBILITY SameMajorVersion)

install(FILES ${CMAKE_CURRENT_BINARY_DIR}/sonor-config.cmake
              ${CMAKE_CURRENT_BINARY_DIR}/sonor-version.cmake
        DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/sonor)

configure_file(cmake/sonor.pc.in
        "${CMAKE_CURRENT_BINARY_DIR}/sonor.pc"
        @ONLY)

install(FILES "${CMAKE_CURRENT_BINARY_DIR}/sonor.pc"
        DESTINATION lib/pkgconfig)

#
# programs, examples and tests
#

if (SONOR_BUILD_TESTS AND NOT CMAKE_JS_VERSION)
    include(CTest)
    add_subdirectory(tests)
endif ()

if (SONOR_BUILD_EXAMPLES)
    add_subdirectory(examples)
endif()

if (MSVC)
    set(MSVC_WARNING_FLAGS
        /wd4101  # Unreferenced local variable
        /wd4005  # Macro redefinition
        /wd4065  # switch statement contains 'default' but no 'case' labels
        /wd4267  # Conversion from 'size_t' to a smaller type, possible loss of data
        /wd4244  # Conversion from one type to another type, possible loss of ata
        /wd4805  # Unsafe mix of type
        /wd4305  # Truncation from 'type1' to 'type2' (often double to float)
        /wd4996  # Function or variable may be unsafe/deprecated
    )
    function(disable_msvc_warnings target_name)
        if(TARGET ${target_name})
            target_compile_options(${target_name} PRIVATE ${MSVC_WARNING_FLAGS})
        endif()
    endfunction()

    if (SONOR_BUILD_EXAMPLES)
        disable_msvc_warnings(sonor)
        disable_msvc_warnings(common)
        disable_msvc_warnings(common-sdl)
        disable_msvc_warnings(lsp)
        disable_msvc_warnings(wchess-core)
        disable_msvc_warnings(sonor-command)
        disable_msvc_warnings(sonor-cli)
        disable_msvc_warnings(sonor-server)
        disable_msvc_warnings(sonor-stream)
        disable_msvc_warnings(sonor-talk-llama)
        disable_msvc_warnings(sonor-bench)
        disable_msvc_warnings(quantize)
        disable_msvc_warnings(vad-speech-segments)
    endif()
endif()
