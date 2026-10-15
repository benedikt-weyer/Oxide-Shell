# Generates protobuf + gRPC C++ bindings from a .proto file and adds them to
# <target>. Mirrors wayland-protocol.cmake's role for Wayland XML protocols:
# codegen happens at build time from the single source of truth (here,
# nix-backend-generic/proto/nix_backend.proto, shared with the Rust server
# that speaks the other end of the same contract).
#
# Usage: caelestia_add_grpc_proto(<target> PROTO_FILE <path/to/x.proto>)
#
# Requires the includer to have already done:
#   find_package(Protobuf CONFIG REQUIRED)
#   find_package(gRPC CONFIG REQUIRED)
function(caelestia_add_grpc_proto target)
    cmake_parse_arguments(arg "" "PROTO_FILE" "" ${ARGN})

    get_filename_component(proto_dir "${arg_PROTO_FILE}" DIRECTORY)
    get_filename_component(proto_name "${arg_PROTO_FILE}" NAME_WE)

    set(generated_dir "${CMAKE_CURRENT_BINARY_DIR}/proto-gen")
    file(MAKE_DIRECTORY "${generated_dir}")

    set(proto_srcs "${generated_dir}/${proto_name}.pb.cc")
    set(proto_hdrs "${generated_dir}/${proto_name}.pb.h")
    set(grpc_srcs "${generated_dir}/${proto_name}.grpc.pb.cc")
    set(grpc_hdrs "${generated_dir}/${proto_name}.grpc.pb.h")

    add_custom_command(
        OUTPUT "${proto_srcs}" "${proto_hdrs}" "${grpc_srcs}" "${grpc_hdrs}"
        COMMAND protobuf::protoc
        ARGS --grpc_out "${generated_dir}"
             --cpp_out "${generated_dir}"
             -I "${proto_dir}"
             --plugin=protoc-gen-grpc=$<TARGET_FILE:gRPC::grpc_cpp_plugin>
             "${arg_PROTO_FILE}"
        DEPENDS "${arg_PROTO_FILE}" protobuf::protoc gRPC::grpc_cpp_plugin
        COMMENT "Generating gRPC bindings for ${proto_name}.proto"
        VERBATIM
    )

    target_sources(${target} PRIVATE "${proto_srcs}" "${grpc_srcs}")
    # SYSTEM: the generated headers (pulled in by hand-written sources) don't
    # meet this project's warning bar either.
    target_include_directories(${target} SYSTEM PRIVATE "${generated_dir}")

    # Generated code doesn't meet this project's own warning bar (and isn't
    # ours to fix), and can't usefully share a PCH built from hand-written
    # headers.
    set_source_files_properties("${proto_srcs}" "${grpc_srcs}" PROPERTIES
        SKIP_PRECOMPILE_HEADERS ON
        COMPILE_OPTIONS "-w"
    )
endfunction()
