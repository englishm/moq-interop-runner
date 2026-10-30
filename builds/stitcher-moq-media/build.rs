//! Records the moq-net and moq-tokio versions Cargo.lock resolved, so the TAP header can
//! name the wire implementation the run used without a hand-maintained constant.

use std::path::Path;

fn locked_version(lock: &str, name: &str) -> String {
    let header = format!("name = \"{}\"", name);
    let mut lines = lock.lines();
    while let Some(line) = lines.next() {
        if line.trim() == header {
            if let Some(version) = lines.next() {
                if let Some(v) = version.trim().strip_prefix("version = ") {
                    return v.trim_matches('"').to_string();
                }
            }
        }
    }
    "unknown".to_string()
}

fn main() {
    let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let lock_path = Path::new(&manifest_dir).join("Cargo.lock");
    println!("cargo:rerun-if-changed={}", lock_path.display());
    let lock = std::fs::read_to_string(&lock_path).unwrap_or_default();
    println!(
        "cargo:rustc-env=MOQ_NET_VERSION={}",
        locked_version(&lock, "moq-net")
    );
    println!(
        "cargo:rustc-env=MOQ_TOKIO_VERSION={}",
        locked_version(&lock, "moq-tokio")
    );
}
