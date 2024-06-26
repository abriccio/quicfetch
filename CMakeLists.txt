cmake_minimum_required(VERSION 3.15)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(LIB_ARTIFACT "${CMAKE_CURRENT_SOURCE_DIR}/zig-out/lib/libquicfetch.a")

if(APPLE)
    set(COMPILE_TARGET "native-apple")
elseif(UNIX)
    set(COMPILE_TARGET "native-linux-musl")
else()
    set(COMPILE_TARGET "native-windows-gnu")
endif()

add_custom_command(OUTPUT ${LIB_ARTIFACT}
    VERBATIM
    COMMAND zig ARGS build -Doptimize=ReleaseSafe -Dtarget=${COMPILE_TARGET}
    WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR}
    DEPENDS quicfetch.zig
)
add_custom_target(quicfetch_build DEPENDS ${LIB_ARTIFACT})

add_library(quicfetch STATIC IMPORTED GLOBAL)
add_dependencies(quicfetch quicfetch_build)
set_target_properties(quicfetch PROPERTIES
    IMPORTED_LOCATION ${LIB_ARTIFACT}
    POSITION_INDEPENDENT_CODE TRUE)
