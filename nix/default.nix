{
  rev,
  lib,
  stdenv,
  makeWrapper,
  makeFontsConf,
  fish,
  ddcutil,
  brightnessctl,
  networkmanager,
  lm_sensors,
  swappy,
  wl-clipboard,
  libqalculate,
  bash,
  material-symbols,
  rubik,
  nerd-fonts,
  qt6,
  quickshell,
  wayland,
  wayland-protocols,
  aubio,
  libcava,
  fftw,
  pipewire,
  xkeyboard-config,
  cmake,
  ninja,
  pkg-config,
  rustPlatform,
  runCommand,
  protobuf,
  grpc,
  abseil-cpp,
  c-ares,
  re2,
  caelestia-cli,
  m3shapes,
  debug ? false,
  withCli ? false,
  extraRuntimeDeps ? [],
}: let
  version = "1.0.0";

  qs = quickshell.withModules [qt6.qtimageformats m3shapes];

  nixBackendGeneric = rustPlatform.buildRustPackage {
    pname = "nix-backend-generic";
    inherit version;
    src = ./../nix-backend-generic;
    cargoLock.lockFile = ./../nix-backend-generic/Cargo.lock;
    # tonic-build (see nix-backend-generic/build.rs) shells out to protoc at build time.
    nativeBuildInputs = [protobuf];

    meta.mainProgram = "nix-backend-generic";
  };

  # First-party plugins (plugins/*), offered by the shell as its default
  # plugin source. Each is a Rust crate built against the plugin SDK
  # (plugin-sdk/rust) and laid out like an installed plugin:
  #   <id>/manifest.json
  #   <id>/<manifest "exec">
  mkPlugin = id:
    rustPlatform.buildRustPackage {
      pname = "caelestia-plugin-${id}";
      version = (lib.importTOML ./../plugins/${id}/Cargo.toml).package.version;
      # The crate depends on the SDK by relative path, so both are needed.
      src = lib.fileset.toSource {
        root = ./..;
        fileset = lib.fileset.unions [./../plugin-sdk/rust ./../plugin-sdk/proto ./../plugins/${id}];
      };
      cargoRoot = "plugins/${id}";
      buildAndTestSubdir = "plugins/${id}";
      cargoLock.lockFile = ./../plugins/${id}/Cargo.lock;
      # tonic-build (the SDK's build.rs) shells out to protoc.
      nativeBuildInputs = [protobuf];

      postInstall = ''
        exec_rel=$(sed -n 's/.*"exec"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' plugins/${id}/manifest.json)
        dest=$out/share/caelestia-shell/plugins/${id}
        mkdir -p "$dest/$(dirname "$exec_rel")"
        install -m644 plugins/${id}/manifest.json "$dest/manifest.json"
        mv $out/bin/"$(basename "$exec_rel")" "$dest/$exec_rel"
        rmdir $out/bin
      '';
    };

  bundledPluginList = map mkPlugin ["pomodoro"];

  # The directory CAELESTIA_BUNDLED_PLUGINS_DIR points at: one real copy per
  # plugin (not symlinks, installing copies them into the user's data dir).
  bundledPlugins = runCommand "caelestia-bundled-plugins" {} ''
    mkdir -p $out
    ${lib.concatMapStringsSep "\n" (p: "cp -r ${p}/share/caelestia-shell/plugins/* $out/") bundledPluginList}
  '';

  runtimeDeps =
    [
      fish
      ddcutil
      brightnessctl
      networkmanager
      lm_sensors
      swappy
      wl-clipboard
      libqalculate
      bash
      nixBackendGeneric
    ]
    ++ extraRuntimeDeps
    ++ lib.optional withCli caelestia-cli;

  fontconfig = makeFontsConf {
    fontDirectories = [material-symbols rubik nerd-fonts.caskaydia-cove];
  };

  cmakeBuildType =
    if debug
    then "Debug"
    else "RelWithDebInfo";

  cmakeVersionFlags = [
    (lib.cmakeFeature "VERSION" version)
    (lib.cmakeFeature "GIT_REVISION" rev)
    (lib.cmakeFeature "DISTRIBUTOR" "nix-flake")
  ];

  extras = stdenv.mkDerivation {
    inherit cmakeBuildType;
    name = "caelestia-extras${lib.optionalString debug "-debug"}";
    src = lib.fileset.toSource {
      root = ./..;
      fileset = lib.fileset.union ./../CMakeLists.txt ./../extras;
    };

    nativeBuildInputs = [cmake ninja];

    cmakeFlags =
      [
        (lib.cmakeFeature "ENABLE_MODULES" "extras")
        (lib.cmakeFeature "INSTALL_LIBDIR" "${placeholder "out"}/lib")
      ]
      ++ cmakeVersionFlags;
  };

  plugin = stdenv.mkDerivation {
    inherit cmakeBuildType;
    name = "caelestia-qml-plugin${lib.optionalString debug "-debug"}";
    src = lib.fileset.toSource {
      root = ./..;
      # plugin/src/Caelestia/NixBackend codegens its gRPC bindings straight
      # from this .proto at build time (see plugin/cmake/grpc-proto.cmake) -
      # the rest of nix-backend-generic (the Rust crate) is built and
      # packaged separately, see nixBackendGeneric below.
      # plugin-sdk/proto is the plugin API Caelestia.Plugins (the host side)
      # generates its gRPC bindings from.
      fileset = lib.fileset.unions [./../CMakeLists.txt ./../plugin ./../nix-backend-generic/proto ./../plugin-sdk/proto];
    };

    nativeBuildInputs = [cmake ninja pkg-config];
    # qt6.qtwayland (Qt6WaylandClient + qtwaylandscanner) and wayland/
    # wayland-protocols (Wayland::Scanner) are for Caelestia.Wayland (see
    # plugin/src/Caelestia/Wayland) - the shell's own client bindings for
    # ironland-compositor's `ironland-shortcuts-v1`/`ironland-focus-grab-v1`,
    # generated from the XML under plugin/protocols at build time.
    #
    # protobuf/grpc (+ their own abseil-cpp/c-ares/re2 link deps, which
    # nixpkgs' grpc/protobuf cmake configs expect *us* to find_package too)
    # are for Caelestia.NixBackend's gRPC client (see
    # plugin/src/Caelestia/NixBackend), codegenerated at build time from
    # ../nix-backend-generic/proto/nix_backend.proto.
    buildInputs = [
      qt6.qtbase
      qt6.qtdeclarative
      qt6.qtshadertools
      qt6.qtwayland
      wayland
      wayland-protocols
      libqalculate
      pipewire
      aubio
      libcava
      fftw
      lm_sensors
      protobuf
      grpc
      abseil-cpp
      c-ares
      re2
    ];

    dontWrapQtApps = true;
    cmakeFlags =
      [
        (lib.cmakeFeature "ENABLE_MODULES" "plugin")
        (lib.cmakeFeature "INSTALL_QMLDIR" qt6.qtbase.qtQmlPrefix)
      ]
      ++ cmakeVersionFlags;
  };
in
  stdenv.mkDerivation {
    inherit version cmakeBuildType;
    pname = "caelestia-shell${lib.optionalString debug "-debug"}";
    src = ./..;

    nativeBuildInputs = [cmake ninja makeWrapper qt6.wrapQtAppsHook];
    buildInputs = [qs extras plugin xkeyboard-config qt6.qtbase];
    propagatedBuildInputs = runtimeDeps;

    cmakeFlags =
      [
        (lib.cmakeFeature "ENABLE_MODULES" "shell")
        (lib.cmakeFeature "INSTALL_QSCONFDIR" "${placeholder "out"}/share/caelestia-shell")
      ]
      ++ cmakeVersionFlags;

    dontStrip = debug;

    prePatch = ''
      substituteInPlace assets/pam.d/fprint \
        --replace-fail pam_fprintd.so /run/current-system/sw/lib/security/pam_fprintd.so
      substituteInPlace assets/pam.d/howdy \
        --replace-fail pam_howdy.so /run/current-system/sw/lib/security/pam_howdy.so
    '';

    postInstall = ''
      makeWrapper ${qs}/bin/qs $out/bin/caelestia-shell \
      	--prefix PATH : "${lib.makeBinPath runtimeDeps}" \
      	--set FONTCONFIG_FILE "${fontconfig}" \
      	--set CAELESTIA_LIB_DIR ${extras}/lib \
      	--set CAELESTIA_BUNDLED_PLUGINS_DIR ${bundledPlugins} \
        --set CAELESTIA_XKB_RULES_PATH ${xkeyboard-config}/share/xkeyboard-config-2/rules/base.lst \
      	--add-flags "-p $out/share/caelestia-shell"

      mkdir -p $out/lib
      ln -s ${extras}/lib/* $out/lib/
    '';

    passthru = {
      inherit plugin extras nixBackendGeneric bundledPlugins;
      plugins = lib.listToAttrs (map (p: lib.nameValuePair p.pname p) bundledPluginList);
    };

    meta = {
      description = "A fluid, morphing shell for your Linux desktop";
      homepage = "https://github.com/caelestia-dots/shell";
      license = lib.licenses.gpl3Only;
      mainProgram = "caelestia-shell";
    };
  }
