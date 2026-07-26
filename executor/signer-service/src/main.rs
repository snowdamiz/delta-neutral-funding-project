use std::error::Error;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Write};
use std::path::Path;

use funding_collector_signer::{BuiltAction, ExecutionIntent, ExecutorPolicy, approve_shadow};
use serde::de::DeserializeOwned;

fn read_json<T: DeserializeOwned>(path: &Path) -> Result<T, Box<dyn Error>> {
    Ok(serde_json::from_slice(&fs::read(path)?)?)
}

fn run(args: &[OsString]) -> Result<(), Box<dyn Error>> {
    if args.len() != 9
        || args[0] != "shadow"
        || args[1] != "--intent"
        || args[3] != "--action"
        || args[5] != "--policy"
        || args[7] != "--now-ms"
    {
        return Err(
            "usage: funding-collector-signer shadow --intent FILE --action FILE --policy FILE --now-ms UNIX_MS"
                .into(),
        );
    }

    let report = approve_shadow(
        &read_json::<ExecutionIntent>(Path::new(&args[2]))?,
        &read_json::<BuiltAction>(Path::new(&args[4]))?,
        &read_json::<ExecutorPolicy>(Path::new(&args[6]))?,
        args[8].to_str().ok_or("--now-ms must be UTF-8")?.parse()?,
    )?;
    let mut output = io::stdout().lock();
    serde_json::to_writer(&mut output, &report)?;
    writeln!(output)?;
    Ok(())
}

fn main() -> Result<(), Box<dyn Error>> {
    run(&std::env::args_os().skip(1).collect::<Vec<_>>())
}
