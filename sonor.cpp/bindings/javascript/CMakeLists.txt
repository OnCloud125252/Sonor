set(TARGET libsonor)

add_executable(${TARGET}
    emscripten.cpp
    )

target_link_libraries(${TARGET} PRIVATE
    sonor
    )

unset(EXTRA_FLAGS)

if (SONOR_WASM_SINGLE_FILE)
    set(EXTRA_FLAGS "-s SINGLE_FILE=1")
    message(STATUS "Embedding WASM inside sonor.js")

    add_custom_command(
        TARGET ${TARGET} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_BINARY_DIR}/bin/libsonor.js
        ${CMAKE_CURRENT_SOURCE_DIR}/sonor.js
        )

    add_custom_command(
        TARGET ${TARGET} POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy
        ${CMAKE_BINARY_DIR}/bin/libsonor.worker.js
        ${CMAKE_CURRENT_SOURCE_DIR}/libsonor.worker.js
        )
endif()

set_target_properties(${TARGET} PROPERTIES LINK_FLAGS " \
    --bind \
    -s MODULARIZE=1 \
    -s EXPORT_NAME=\"'sonor_factory'\" \
    -s FORCE_FILESYSTEM=1 \
    -s USE_PTHREADS=1 \
    -s PTHREAD_POOL_SIZE=8 \
    -s ALLOW_MEMORY_GROWTH=1 \
    ${EXTRA_FLAGS} \
    ")
