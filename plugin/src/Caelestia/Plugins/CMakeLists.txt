qml_module(caelestia-plugins
    URI Caelestia.Plugins
    SOURCES
        pluginstore.cpp
        pluginhost.cpp
        pluginmanager.cpp
    LIBRARIES
        Qt::Network
        Qt::Concurrent
        gRPC::grpc++
        protobuf::libprotobuf
)

# Host baked-in version is reported to plugins during the handshake.
target_compile_definitions(caelestia-plugins PRIVATE CAELESTIA_VERSION="${VERSION}")

caelestia_add_grpc_proto(caelestia-plugins
    PROTO_FILE "${CMAKE_SOURCE_DIR}/plugin-sdk/proto/caelestia_plugin.proto"
)

# End-to-end test of the host against the real pomodoro plugin, see
# tests/plugin_e2e.cpp. Opt-in: needs scripts/build-plugins.sh to have run.
option(CAELESTIA_BUILD_PLUGIN_TESTS "Build the plugin system end-to-end test" OFF)
if(CAELESTIA_BUILD_PLUGIN_TESTS)
    find_package(Qt6 REQUIRED COMPONENTS Test)
    enable_testing()
    qt_add_executable(caelestia-plugins-e2e tests/plugin_e2e.cpp)
    set_target_properties(caelestia-plugins-e2e PROPERTIES AUTOMOC ON)
    target_include_directories(caelestia-plugins-e2e PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
    target_link_libraries(caelestia-plugins-e2e PRIVATE caelestia-plugins Qt6::Test Qt6::Network Qt6::Qml)
    add_test(NAME plugins-e2e COMMAND caelestia-plugins-e2e)
    set_tests_properties(plugins-e2e PROPERTIES
        ENVIRONMENT "CAELESTIA_BUNDLED_PLUGINS_DIR=${CMAKE_BINARY_DIR}/plugins;QT_QPA_PLATFORM=offscreen"
        TIMEOUT 120)
endif()
