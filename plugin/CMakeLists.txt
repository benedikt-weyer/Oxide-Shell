find_package(Qt6 REQUIRED COMPONENTS ShaderTools Core Qml Gui GuiPrivate Quick QuickControls2 Concurrent Sql Network DBus WaylandClient)
find_package(PkgConfig REQUIRED)
pkg_check_modules(Qalculate IMPORTED_TARGET libqalculate REQUIRED)
pkg_check_modules(Pipewire IMPORTED_TARGET libpipewire-0.3 REQUIRED)
pkg_check_modules(Aubio IMPORTED_TARGET aubio REQUIRED)
pkg_check_modules(Cava IMPORTED_TARGET libcava QUIET)
if(NOT Cava_FOUND)
    pkg_check_modules(Cava IMPORTED_TARGET cava REQUIRED)
endif()
# For Caelestia.Plugins' gRPC client (see plugin/src/Caelestia/Plugins).
find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)
include(cmake/sensorslib.cmake)

set(QT_QML_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/qml")
qt_standard_project_setup(REQUIRES 6.9)

include(cmake/pch.cmake)
include(cmake/qml-module.cmake)
include(cmake/wayland-protocol.cmake)
include(cmake/grpc-proto.cmake)

# Header only helpers
add_library(caelestia-util INTERFACE)
target_include_directories(caelestia-util INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")

add_subdirectory(src/Caelestia)
