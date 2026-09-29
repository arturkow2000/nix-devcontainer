use std::{fs, io, os::unix::fs::MetadataExt, path::Path};

use serde::{Serialize, Serializer};

#[derive(Serialize)]
#[serde(rename_all = "lowercase")]
pub enum FileType {
    Regular,
    Directory,
}

#[derive(Serialize, Clone, Copy)]
pub struct Entry<'a> {
    path: &'a Path,
    uid: u32,
    gid: u32,
    #[serde(serialize_with = "serialize_octal")]
    mode: u32,
    #[serde(skip_serializing_if = "Option::is_none")]
    target: Option<&'a Path>,
}

fn serialize_octal<S>(v: &u32, ser: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
{
    ser.serialize_str(&format!("{v:#o}"))
}

fn report(entry: Entry) {
    serde_json::ser::to_writer(&mut io::stdout(), &entry).unwrap();
    println!()
}

fn dump(path: &Path) {
    for rd in fs::read_dir(path).unwrap() {
        let entry = rd.unwrap();
        let ft = entry.file_type().unwrap();
        let meta = entry.metadata().unwrap();
        let target = if meta.is_symlink() {
            Some(fs::read_link(entry.path()).unwrap())
        } else {
            None
        };

        let path = entry.path();
        if path == Path::new("/dev") || path == Path::new("/sys") || path == Path::new("/proc") {
            continue;
        }

        report(Entry {
            path: &path,
            uid: meta.uid(),
            gid: meta.gid(),
            mode: meta.mode() & 0o7777,
            target: target.as_deref(),
        });

        if ft.is_dir() {
            // We will just check derivation paths, not contents.
            // In fact these may differ between nix2container and nix-snapshotter.
            // With nix2container we copy some files to /etc and remove original
            // files from /nix/store (content deduplication and access enforcement - we may
            // set permissions on /etc files but on /nix/store).
            // In case of nix-snapshotter we don't have such control - derivations are
            // bind-mounted into container as a whole.
            if !path.starts_with("/nix/store") || path == Path::new("/nix/store") {
                dump(&path);
            }
        }
    }
}

fn main() {
    dump(Path::new("/"));
}
