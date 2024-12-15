cmake_minimum_required(VERSION 3.15)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(LIB_ARTIFACT "${CMAKE_CURRENT_SOURCE_DIR}/zig-out/lib/libquicfetch.a")

if (UNIX AND NOT APPLE)
    set(LIB_TARGET "native-linux-musl")
else()
    set(LIB_TARGET "native")
endif()

add_custom_command(OUTPUT ${LIB_ARTIFACT}
    VERBATIM
    COMMAND zig ARGS build -Doptimize=ReleaseFast -Dtarget=${LIB_TARGET}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS quicfetch.zig build.zig
)
add_custom_target(quicfetch_build DEPENDS ${LIB_ARTIFACT})

add_library(quicfetch STATIC IMPORTED GLOBAL)
add_dependencies(quicfetch quicfetch_build)
set_target_properties(quicfetch PROPERTIES
    IMPORTED_LOCATION ${LIB_ARTIFACT}
    POSITION_INDEPENDENT_CODE TRUE)
