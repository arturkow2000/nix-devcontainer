use std::{
    ffi::OsStr,
    mem::forget,
    os::unix::ffi::OsStrExt,
    pin::Pin,
    task::{Context, Poll, ready},
};

use async_tar::{EntryType, Header, HeaderMode};
use futures_util::{Stream, StreamExt, io::Cursor};
use pin_project::pin_project;
use snafu::{ResultExt, Snafu};
use tokio::{
    fs,
    io::{self, AsyncBufReadExt, AsyncRead, AsyncWrite, BufReader, Lines},
};

mod entry;
pub use entry::*;
use tokio_util::compat::FuturesAsyncReadCompatExt as _;
use typed_path::{UnixComponent, UnixPathBuf};

#[derive(Debug, Snafu)]
pub enum Error {
    #[snafu(display("I/O error"))]
    Io { source: io::Error },

    #[snafu(transparent)]
    Deserialize { source: serde_json::Error },
}

#[pin_project]
pub struct SpecStream<R: AsyncRead> {
    #[pin]
    reader: Lines<BufReader<R>>,
}
impl<R: AsyncRead> SpecStream<R> {
    pub fn from_jsonl_stream(reader: R) -> Self {
        Self {
            reader: BufReader::new(reader).lines(),
        }
    }
}
impl<R: AsyncRead> Stream for SpecStream<R> {
    type Item = Result<Entry, Error>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let Some(line) = ready!(self.project().reader.poll_next_line(cx)).context(IoSnafu)? else {
            return Poll::Ready(None);
        };
        Poll::Ready(Some(
            serde_json::from_str(&line).map_err(|source| Error::Deserialize { source }),
        ))
    }
}

pub async fn stream_layer<W: AsyncWrite + Unpin + Send + Sync>(
    mut spec: Pin<&mut impl Stream<Item = Result<Entry, Error>>>,
    out: &mut W,
) -> Result<(), Error> {
    let mut tar = async_tar::Builder::new(out);
    tar.mode(HeaderMode::Deterministic);
    tar.follow_symlinks(false);

    let result = (async || {
        while let Some(entry) = spec.next().await.transpose()? {
            fn new_header(path: UnixPathBuf, uid: u64, gid: u64, mode: u16) -> Header {
                let path_fixed: UnixPathBuf = path
                    .components()
                    .map(|comp| match comp {
                        UnixComponent::ParentDir | UnixComponent::CurDir => unreachable!(),
                        UnixComponent::RootDir => UnixComponent::CurDir,
                        UnixComponent::Normal(n) => UnixComponent::Normal(n),
                    })
                    .collect();

                let mut header = Header::new_gnu();
                header
                    .set_path(OsStr::from_bytes(path_fixed.as_bytes()))
                    .unwrap();
                header.set_uid(uid);
                header.set_gid(gid);
                header.set_mode(mode as _);
                header
            }

            match entry {
                Entry::Directory {
                    path,
                    uid,
                    gid,
                    mode,
                } => {
                    let mut header = new_header(path, uid, gid, mode);
                    header.set_entry_type(EntryType::Directory);
                    header.set_cksum();
                    tar.append(&header, &mut io::empty())
                        .await
                        .context(IoSnafu)?;
                }
                Entry::Regular {
                    path,
                    source,
                    uid,
                    gid,
                    mode,
                } => {
                    let mut header = new_header(path, uid, gid, mode);
                    header.set_entry_type(EntryType::Regular);
                    match source {
                        Source::Inline { contents } => {
                            header.set_size(contents.len() as _);
                            header.set_cksum();
                            tar.append(&header, Cursor::new(contents).compat())
                                .await
                                .context(IoSnafu)?;
                        }
                        Source::From { path } => {
                            let file = fs::File::open(&path).await.context(IoSnafu)?;
                            let meta = file.metadata().await.context(IoSnafu)?;
                            header.set_size(meta.len() as _);
                            header.set_cksum();
                            tar.append(&header, file).await.context(IoSnafu)?;
                        }
                    }
                }
                Entry::Symlink {
                    path,
                    target,
                    uid,
                    gid,
                } => {
                    let mut header = new_header(path, uid, gid, 0o777);
                    header.set_entry_type(EntryType::Symlink);
                    header
                        .set_link_name(OsStr::from_bytes(target.as_bytes()))
                        .unwrap();
                    header.set_cksum();
                    tar.append(&header, io::empty()).await.context(IoSnafu)?;
                }
            }
        }

        Ok(())
    })()
    .await;

    match result {
        Ok(()) => tar.finish().await.context(IoSnafu)?,
        Err(error) => {
            forget(tar);
            return Err(error);
        }
    }

    Ok(())
}
