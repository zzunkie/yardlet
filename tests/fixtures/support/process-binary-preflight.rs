use std::path::Path;
use std::process::Command;

#[derive(Clone, Copy)]
pub struct CliCapability {
    pub name: &'static str,
    pub probe_args: &'static [&'static str],
    pub marker: &'static str,
}

pub fn preflight_process_binary(binary: &Path, required: &[CliCapability]) -> Result<(), String> {
    let missing = required
        .iter()
        .filter(|capability| {
            let Ok(output) = Command::new(binary).args(capability.probe_args).output() else {
                return true;
            };
            if !output.status.success() {
                return true;
            }
            let mut help = output.stdout;
            help.extend_from_slice(&output.stderr);
            !String::from_utf8_lossy(&help).contains(capability.marker)
        })
        .map(|capability| capability.name)
        .collect::<Vec<_>>();
    if missing.is_empty() {
        return Ok(());
    }

    let confirm = required
        .first()
        .map(|capability| capability.probe_args.join(" "))
        .unwrap_or_else(|| "--help".to_string());
    Err(format!(
        "process binary capability preflight failed\n\
         target binary: {}\n\
         missing required CLI capability(s): {}\n\
         The target Yardlet build artifact may be older than the process test source.\n\
         Run cargo clean -p yardlet, rebuild with cargo build --bin yardlet, confirm with {} {}, then retry. Process fixture body was not started.",
        binary.display(),
        missing.join(", "),
        binary.display(),
        confirm,
    ))
}
