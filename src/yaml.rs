//! YAML facade.
//!
//! All YAML (de)serialization goes through this module so the concrete crate
//! stays swappable. If we change the backing YAML implementation, only this
//! file and `Cargo.toml` need to change.

pub use serde_yaml_ng::Value;

use serde::de::DeserializeOwned;
use serde::Serialize;

pub fn from_str<T: DeserializeOwned>(s: &str) -> anyhow::Result<T> {
    Ok(serde_yaml_ng::from_str(s)?)
}

pub fn to_string<T: Serialize>(value: &T) -> anyhow::Result<String> {
    Ok(serde_yaml_ng::to_string(value)?)
}
