set(TARGET sonor-quantize)
add_executable(${TARGET} quantize.cpp)

include(DefaultTargetOptions)

target_link_libraries(${TARGET} PRIVATE common sonor ${CMAKE_THREAD_LIBS_INIT})
install(TARGETS ${TARGET} RUNTIME)
