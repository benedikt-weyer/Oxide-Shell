{
  lib,
  stdenv,
  cmake,
  ninja,
  protobuf,
  grpc,
  abseil-cpp,
  c-ares,
  re2,
  openssl,
  zlib,
}:
stdenv.mkDerivation {
  pname = "caelestia-plugin-sdk-cpp";
  version = "1.0.0";

  # The SDK's CMake reuses plugin/cmake/grpc-proto.cmake and generates its
  # bindings from the shared plugin-sdk/proto.
  src = lib.fileset.toSource {
    root = ./..;
    fileset = lib.fileset.unions [./../plugin-sdk ./../plugin/cmake/grpc-proto.cmake];
  };
  sourceRoot = "source/plugin-sdk/cpp";

  nativeBuildInputs = [cmake ninja];
  buildInputs = [protobuf grpc abseil-cpp c-ares re2 openssl zlib];

  # Runs the SDK's roundtrip test (a plugin served and driven over a real socket).
  doCheck = true;

  meta = {
    description = "C++ SDK for caelestia-shell plugins";
    license = lib.licenses.gpl3Only;
  };
}
