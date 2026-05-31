use std::process::Command; fn main() { let output = Command::new("cargo").arg("metadata").output().unwrap(); println!("cargo:warning=output {:?}", output.status); }
