fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The daemon's contract is shared with nix-backend-generic (the server)
    // rather than copied, so both ends always agree.
    let proto_dir = "../../nix-backend-generic/proto";
    println!("cargo:rerun-if-changed={proto_dir}/nix_backend.proto");
    tonic_build::configure()
        .build_server(true) // only used by the tests' fake daemon
        .compile(&["nix_backend.proto"], &[proto_dir])?;
    Ok(())
}
