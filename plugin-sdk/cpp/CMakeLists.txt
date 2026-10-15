cmake_minimum_required(VERSION 3.19)

# Standalone-buildable: `cmake -S plugin-sdk/cpp -B build-sdk`. Also added to
# the shell's build with ENABLE_MODULES+=plugin-sdk-cpp.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(caelestia-plugin-sdk-cpp LANGUAGES CXX)
    set(CMAKE_CXX_STANDARD 20)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_CXX_EXTENSIONS OFF)
endif()

find_package(Protobuf CONFIG REQUIRED)
find_package(gRPC CONFIG REQUIRED)
include("${CMAKE_CURRENT_LIST_DIR}/../../plugin/cmake/grpc-proto.cmake")

add_library(caelestia-plugin-sdk STATIC src/plugin.cpp)
add_library(Caelestia::PluginSdk ALIAS caelestia-plugin-sdk)
target_compile_features(caelestia-plugin-sdk PUBLIC cxx_std_20)
target_include_directories(caelestia-plugin-sdk PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    $<INSTALL_INTERFACE:include>
)
# gRPC/protobuf stay out of the public headers.
target_link_libraries(caelestia-plugin-sdk PRIVATE gRPC::grpc++ protobuf::libprotobuf)
set_target_properties(caelestia-plugin-sdk PROPERTIES POSITION_INDEPENDENT_CODE ON)

caelestia_add_grpc_proto(caelestia-plugin-sdk
    PROTO_FILE "${CMAKE_CURRENT_LIST_DIR}/../proto/caelestia_plugin.proto"
)

install(TARGETS caelestia-plugin-sdk ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)

# Views and schemas are written as designated-initializer literals that leave
# defaulted members out on purpose; -Wextra flags every one of them.
function(caelestia_plugin_sdk_quiet_designated target)
    if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        target_compile_options(${target} PRIVATE -Wno-missing-designated-field-initializers)
    else()
        target_compile_options(${target} PRIVATE -Wno-missing-field-initializers)
    endif()
endfunction()

option(CAELESTIA_PLUGIN_SDK_EXAMPLES "Build the C++ SDK example plugin" ON)
if(CAELESTIA_PLUGIN_SDK_EXAMPLES)
    add_executable(caelestia-plugin-hello examples/hello/main.cpp)
    target_link_libraries(caelestia-plugin-hello PRIVATE caelestia-plugin-sdk)
    caelestia_plugin_sdk_quiet_designated(caelestia-plugin-hello)
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(caelestia-plugin-sdk-test tests/roundtrip.cpp)
    target_link_libraries(caelestia-plugin-sdk-test PRIVATE caelestia-plugin-sdk gRPC::grpc++ protobuf::libprotobuf)
    # The test speaks the raw protocol, like the shell does.
    target_include_directories(caelestia-plugin-sdk-test SYSTEM PRIVATE "${CMAKE_CURRENT_BINARY_DIR}/proto-gen")
    add_dependencies(caelestia-plugin-sdk-test caelestia-plugin-sdk)
    caelestia_plugin_sdk_quiet_designated(caelestia-plugin-sdk-test)
    add_test(NAME plugin-sdk-roundtrip COMMAND caelestia-plugin-sdk-test)
endif()
