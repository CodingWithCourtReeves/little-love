use clap::Parser;

use littlelove_bot::cli;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let args = cli::Cli::parse();
    match args.command {
        cli::Command::Pair(args) => littlelove_bot::pair::run(args).await,
        cli::Command::Run(_) => {
            anyhow::bail!("run: not yet implemented");
        }
        cli::Command::ShowIdentity => {
            anyhow::bail!("show-identity: not yet implemented");
        }
    }
}
