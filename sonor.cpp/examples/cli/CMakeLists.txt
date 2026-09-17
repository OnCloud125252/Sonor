set(TARGET sonor-cli)
add_executable(${TARGET} cli.cpp)

include(DefaultTargetOptions)

target_link_libraries(${TARGET} PRIVATE common sonor ${FFMPEG_LIBRARIES} ${CMAKE_THREAD_LIBS_INIT})

install(TARGETS ${TARGET} RUNTIME)
