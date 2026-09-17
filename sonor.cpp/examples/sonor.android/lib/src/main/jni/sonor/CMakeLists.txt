cmake_minimum_required(VERSION 3.10)

project(sonor.cpp)

set(CMAKE_CXX_STANDARD 17)
set(SONOR_LIB_DIR ${CMAKE_SOURCE_DIR}/../../../../../../..)

# Get sonor.cpp version
file(READ "${SONOR_LIB_DIR}/CMakeLists.txt" MAIN_CMAKE_CONTENT)
string(REGEX MATCH "project\\(\"sonor\\.cpp\" VERSION ([0-9]+\\.[0-9]+\\.[0-9]+)\\)" VERSION_MATCH "${MAIN_CMAKE_CONTENT}")
if(CMAKE_MATCH_1)
    set(SONOR_VERSION ${CMAKE_MATCH_1} PARENT_SCOPE)
else()
    set(SONOR_VERSION "unknown" PARENT_SCOPE)
endif()

message(STATUS " Sonor version: ${SONOR_VERSION}")

# Path to external GGML, otherwise uses the copy in sonor.cpp.
option(GGML_HOME "sonor: Path to external GGML source" OFF)

set(
    SOURCE_FILES
    ${SONOR_LIB_DIR}/src/sonor.cpp
    ${CMAKE_SOURCE_DIR}/jni.c
    )

find_library(LOG_LIB log)

include(FetchContent)

function(build_library target_name)
    add_library(
        ${target_name}
        SHARED
        ${SOURCE_FILES}
    )

    target_compile_definitions(${target_name} PUBLIC GGML_USE_CPU)
    target_compile_definitions(${target_name} PRIVATE SONOR_VERSION="${SONOR_VERSION}")

    if (${target_name} STREQUAL "sonor_v8fp16_va")
        target_compile_options(${target_name} PRIVATE -march=armv8.2-a+fp16)
        set(GGML_COMPILE_OPTIONS                      -march=armv8.2-a+fp16)
    elseif (${target_name} STREQUAL "sonor_vfpv4")
        target_compile_options(${target_name} PRIVATE -mfpu=neon-vfpv4)
        set(GGML_COMPILE_OPTIONS                      -mfpu=neon-vfpv4)
    endif ()

    if (NOT ${CMAKE_BUILD_TYPE} STREQUAL "Debug")
        target_compile_options(${target_name} PRIVATE -O3)
        target_compile_options(${target_name} PRIVATE -fvisibility=hidden -fvisibility-inlines-hidden)
        target_compile_options(${target_name} PRIVATE -ffunction-sections -fdata-sections)

        target_link_options(${target_name} PRIVATE -Wl,--gc-sections)
        target_link_options(${target_name} PRIVATE -Wl,--exclude-libs,ALL)
        target_link_options(${target_name} PRIVATE -flto)
    endif ()

    if (GGML_HOME)
        FetchContent_Declare(ggml SOURCE_DIR ${GGML_HOME})
    else()
        FetchContent_Declare(ggml SOURCE_DIR ${SONOR_LIB_DIR}/ggml)
    endif()
    FetchContent_MakeAvailable(ggml)
    target_compile_options(ggml PRIVATE ${GGML_COMPILE_OPTIONS})
    target_link_libraries(${target_name} ${LOG_LIB} android ggml)


endfunction()

if (${ANDROID_ABI} STREQUAL "arm64-v8a")
    build_library("sonor_v8fp16_va")
elseif (${ANDROID_ABI} STREQUAL "armeabi-v7a")
    build_library("sonor_vfpv4")
endif ()

build_library("sonor") # Default target

include_directories(${SONOR_LIB_DIR})
include_directories(${SONOR_LIB_DIR}/src)
include_directories(${SONOR_LIB_DIR}/include)
include_directories(${SONOR_LIB_DIR}/ggml/include)
include_directories(${SONOR_LIB_DIR}/ggml/src)
include_directories(${SONOR_LIB_DIR}/ggml/src/ggml-cpu)

