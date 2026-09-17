# TODO: should not use this
if (WIN32)
    add_compile_definitions(_CRT_SECURE_NO_WARNINGS)

    if (BUILD_SHARED_LIBS)
        set(CMAKE_WINDOWS_EXPORT_ALL_SYMBOLS ON)
    endif()
endif()


if (SONOR_ALL_WARNINGS)
    if (NOT MSVC)
        list(APPEND WARNING_FLAGS -Wall -Wextra -Wpedantic -Wcast-qual -Wno-unused-function)
        list(APPEND C_FLAGS       -Wshadow -Wstrict-prototypes -Wpointer-arith -Wmissing-prototypes
                                  -Werror=implicit-int -Werror=implicit-function-declaration)
        list(APPEND CXX_FLAGS     -Wmissing-declarations -Wmissing-noreturn)

        list(APPEND C_FLAGS   ${WARNING_FLAGS})
        list(APPEND CXX_FLAGS ${WARNING_FLAGS})

        add_compile_options("$<$<COMPILE_LANGUAGE:C>:${C_FLAGS}>"
                            "$<$<COMPILE_LANGUAGE:CXX>:${CXX_FLAGS}>")
    else()
        # todo : msvc
        set(C_FLAGS   "")
        set(CXX_FLAGS "")
    endif()
endif()

if (SONOR_COREML)
    find_library(FOUNDATION_FRAMEWORK Foundation)
    find_library(COREML_FRAMEWORK CoreML)

    if (COREML_FRAMEWORK)
        message(STATUS "CoreML framework found")

        set(SONOR_EXTRA_FLAGS ${SONOR_EXTRA_FLAGS} -DSONOR_USE_COREML)
    else()
        message(FATAL_ERROR "CoreML framework not found")
    endif()

    if (SONOR_COREML_ALLOW_FALLBACK)
        set(SONOR_EXTRA_FLAGS ${SONOR_EXTRA_FLAGS} -DSONOR_COREML_ALLOW_FALLBACK)
    endif()
endif()

if (SONOR_OPENVINO)
    find_package(OpenVINO REQUIRED COMPONENTS Runtime)
endif()

#
# libraries
#

# sonor.coreml

if (SONOR_COREML)
    set(TARGET sonor.coreml)

    add_library(${TARGET}
        coreml/sonor-compat.m
        coreml/sonor-encoder.h
        coreml/sonor-encoder.mm
        coreml/sonor-encoder-impl.h
        coreml/sonor-encoder-impl.m
        )

    include(DefaultTargetOptions)

    target_include_directories(${TARGET} PUBLIC
        .
        )

    target_link_libraries(${TARGET} PRIVATE ${FOUNDATION_FRAMEWORK} ${COREML_FRAMEWORK})

    set_target_properties(${TARGET} PROPERTIES
        COMPILE_FLAGS "-fobjc-arc"
        XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
        )

    set_target_properties(${TARGET} PROPERTIES FOLDER "libs")
    install(TARGETS ${TARGET} LIBRARY)
endif()

if (SONOR_OPENVINO)
    set(TARGET sonor.openvino)

    add_library(${TARGET} OBJECT
        openvino/sonor-openvino-encoder.h
        openvino/sonor-openvino-encoder.cpp
        )

    target_include_directories(${TARGET} PUBLIC
        .
        )

    set_property(TARGET ${TARGET} PROPERTY POSITION_INDEPENDENT_CODE ON)
    set(SONOR_EXTRA_FLAGS ${SONOR_EXTRA_FLAGS} -DSONOR_USE_OPENVINO)

    target_link_libraries(${TARGET} PRIVATE ggml openvino::runtime)
    set_target_properties(${TARGET} PROPERTIES FOLDER "libs")
endif()

# sonor

add_library(sonor
            ../include/sonor.h
            sonor-arch.h
            sonor.cpp
            )

# Set the version numbers
set_target_properties(sonor PROPERTIES
    VERSION ${PROJECT_VERSION}
    SOVERSION ${SOVERSION}
)

target_include_directories(sonor PUBLIC . ../include)
target_compile_features   (sonor PUBLIC cxx_std_11) # don't bump

if (CMAKE_CXX_BYTE_ORDER STREQUAL "BIG_ENDIAN")
    set(SONOR_EXTRA_FLAGS ${SONOR_EXTRA_FLAGS} -DSONOR_BIG_ENDIAN)
endif()

if (SONOR_EXTRA_FLAGS)
    target_compile_options(sonor PRIVATE ${SONOR_EXTRA_FLAGS})
endif()

find_package(Threads REQUIRED)
target_link_libraries(sonor PUBLIC ggml Threads::Threads)

if (SONOR_COREML)
    target_link_libraries(sonor PRIVATE sonor.coreml)
endif()

if (SONOR_OPENVINO)
    target_link_libraries(sonor PRIVATE sonor.openvino)
endif()

if (SONOR_MKL)
    target_link_libraries(sonor PRIVATE MKL::MKL)
endif()

if (BUILD_SHARED_LIBS)
    set_target_properties(sonor PROPERTIES POSITION_INDEPENDENT_CODE ON)
    target_compile_definitions(sonor PRIVATE SONOR_SHARED SONOR_BUILD)
endif()
