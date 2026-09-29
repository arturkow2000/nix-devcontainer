use std::{path::PathBuf, pin::pin};

use clap::Parser;
use tokio::{
    fs::File,
    io::{self, AsyncRead},
};

#[derive(Parser)]
struct Options {
    /// Input path to .jsonl file, or '-' to read from stdin.
    input: PathBuf,

    /// Output path, or '-' to write to stdout.
    #[arg(long)]
    output: Option<PathBuf>,
}

#[tokio::main]
async fn main() -> eyre::Result {
    let opts = Options::parse();
    let mut file_in = None;
    let input: &mut (dyn AsyncRead + Unpin) = if opts.input.as_os_str() == "-" {
        &mut io::stdin()
    } else {
        file_in.insert(File::open(&opts.input).await?)
    };
    let input = pin!(mklayer::SpecStream::from_jsonl_stream(input));
    if let Some(path) = opts.output.as_ref() {
        if path.as_os_str() == "-" {
            mklayer::stream_layer(input, &mut io::stdout()).await?;
        } else {
            mklayer::stream_layer(input, &mut File::create(&path).await?).await?;
        }
    } else {
        mklayer::stream_layer(input, &mut io::stdout()).await?;
    }

    Ok(())
}
