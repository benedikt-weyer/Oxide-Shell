fn main() -> Result<(), Box<dyn std::error::Error>> {
    // The proto is shared with the shell and the C++ SDK, so it lives next to
    // this crate rather than inside it.
    let proto_dir = "../proto";
    println!("cargo:rerun-if-changed={proto_dir}/caelestia_plugin.proto");
    tonic_build::configure()
        .build_server(true)
        .build_client(true) // used by the SDK's own tests
        .compile(&["caelestia_plugin.proto"], &[proto_dir])?;
    Ok(())
}
