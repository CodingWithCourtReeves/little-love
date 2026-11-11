//! `sqlx::migrate!("./migrations")` embeds the migration files at compile
//! time, but Cargo doesn't know they're inputs: without this, adding a
//! migration leaves an incremental build running the old set (CI's clean
//! builds hide it). Rebuild whenever the folder changes.
fn main() {
    println!("cargo:rerun-if-changed=migrations");
}
