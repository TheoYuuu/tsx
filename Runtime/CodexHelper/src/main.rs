//! Native-only, one-operation entry point. The production binary accepts no
//! endpoint, issuer, account-home, credential, or diagnostics overrides.
use lumax_codex_runtime::{host, protocol, supervisor, worker};
use protocol::{Event, Outcome, Request, WorkerInput};
use std::io::BufReader;

fn main() {
    // Do not let panic diagnostics echo a credential-bearing upstream value.
    // A nonzero exit without a valid terminal is a host failure, never success.
    std::panic::set_hook(Box::new(|_| {}));
    let code = entry();
    std::process::exit(code);
}

fn entry() -> i32 {
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let inherited = match args.as_slice() {
        [] => None,
        [mode, fd] if mode == "--worker" => match fd.to_str().and_then(|value| value.parse::<i32>().ok()) {
            Some(fd) => match worker::take_lease(fd) { Ok(file) => Some(file), Err(_) => return 64 },
            None => return 64,
        },
        _ => return 64,
    };
    let mut reader = BufReader::new(std::io::stdin());
    let line = match protocol::read_bounded_line(&mut reader, protocol::MAX_INPUT_LINE) {
        Ok(Some(value)) => value,
        _ => return 64,
    };
    let (request, worker_input) = if inherited.is_some() {
        let Ok(input) = serde_json::from_slice::<WorkerInput>(&line) else { return 64 };
        if !matches!(protocol::read_bounded_line(&mut reader, protocol::MAX_CONTROL_LINE), Ok(None)) { return 64; }
        (input.request.clone(), Some(input))
    } else {
        let Ok(request) = serde_json::from_slice::<Request>(&line) else { return 64 };
        (request, None)
    };
    if !request.valid() { return 64; }
    if !host::allowed_environment() {
        return terminal_error(&request, "environment_rejected");
    }
    let root = match host::account_root() {
        Ok(value) => value,
        Err(_) => return terminal_error(&request, "storage_unavailable"),
    };
    // No global tracing subscriber, auth environment, or user configuration is
    // installed. In particular tokio-spawned upstream SSE tasks remain silent.
    let runtime = match tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build() {
        Ok(value) => value,
        Err(_) => return terminal_error(&request, "request_failed"),
    };
    match (inherited, worker_input) {
        (Some(lease), Some(input)) => runtime.block_on(worker::run(&root, lease, input)),
        (None, None) => runtime.block_on(supervisor::run(request, root, reader)),
        _ => 64,
    }
}

fn terminal_error(request: &Request, code: &str) -> i32 {
    if worker::write_event(&Event::terminal(request, Outcome::error(code))).is_ok() { 0 } else { 74 }
}
