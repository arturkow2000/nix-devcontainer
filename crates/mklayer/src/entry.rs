use std::path::PathBuf;

use serde::{Deserialize, Deserializer, de};
use typed_path::{UnixComponent, UnixPathBuf};

#[derive(Debug, Deserialize)]
#[serde(untagged)]
pub enum Source {
    Inline {
        contents: Vec<u8>,
    },
    From {
        #[serde(rename = "source")]
        path: PathBuf,
    },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "lowercase")]
#[serde(tag = "type")]
pub enum Entry {
    Directory {
        #[serde(deserialize_with = "deserialize_canonical_path")]
        path: UnixPathBuf,

        #[serde(default)]
        uid: u64,

        #[serde(default)]
        gid: u64,

        #[serde(default = "default_dir_mode", deserialize_with = "deserialize_mode")]
        mode: u16,
    },

    Regular {
        #[serde(deserialize_with = "deserialize_canonical_path")]
        path: UnixPathBuf,

        #[serde(flatten)]
        source: Source,

        #[serde(default)]
        uid: u64,

        #[serde(default)]
        gid: u64,

        #[serde(default = "default_file_mode", deserialize_with = "deserialize_mode")]
        mode: u16,
    },

    Symlink {
        #[serde(deserialize_with = "deserialize_canonical_path")]
        path: UnixPathBuf,
        target: UnixPathBuf,

        #[serde(default)]
        uid: u64,

        #[serde(default)]
        gid: u64,
    },
}

const fn default_dir_mode() -> u16 {
    0o755
}

const fn default_file_mode() -> u16 {
    0o644
}

fn deserialize_mode<'de, D>(de: D) -> Result<u16, D::Error>
where
    D: Deserializer<'de>,
{
    let s = String::deserialize(de)?;
    u16::from_str_radix(&s, 8).map_err(|_| de::Error::custom("invalid octal number"))
}

fn deserialize_canonical_path<'de, D>(de: D) -> Result<UnixPathBuf, D::Error>
where
    D: Deserializer<'de>,
{
    let path = UnixPathBuf::deserialize(de)?;
    if !path.is_absolute() {
        return Err(de::Error::custom("path is not canonical"));
    }
    for comp in path.components() {
        match comp {
            UnixComponent::ParentDir | UnixComponent::CurDir => {
                return Err(de::Error::custom("path is not canonical"));
            }
            _ => (),
        }
    }
    Ok(path)
}
