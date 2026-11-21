fn main() {
    println!("cargo:rerun-if-env-changed=XBOXPAD_BUILTIN_ICE_NODES");
    println!("cargo:rerun-if-env-changed=XBOXPAD_BUILTIN_TURN_USER");
    println!("cargo:rerun-if-env-changed=XBOXPAD_BUILTIN_TURN_PASS");
}
