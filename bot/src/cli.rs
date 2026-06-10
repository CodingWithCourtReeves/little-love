use clap::{Parser, Subcommand};

#[derive(Parser, Debug)]
#[command(
    name = "littlelove-bot",
    version,
    about = "Local-AI bot for LittleLove"
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// First-time pairing: signup + consume invite + persist identity.
    Pair(PairArgs),
    /// Connect, subscribe to the room, respond to inbound messages.
    Run(RunArgs),
    /// Print this bot's username and public-key fingerprints.
    ShowIdentity,
    /// Inspect the bot's identity + per-room memory state without writing.
    Doctor(DoctorArgs),
}

#[derive(clap::Args, Debug)]
pub struct DoctorArgs {
    #[arg(long, env = "LITTLELOVE_BOT_MEMORY_DIR")]
    pub memory_dir: Option<std::path::PathBuf>,
}

#[derive(clap::Args, Debug)]
pub struct PairArgs {
    /// WSS server URL, e.g. wss://littlelove.example.org
    #[arg(long, env = "LITTLELOVE_BOT_SERVER")]
    pub server: String,

    /// 4-word invite code.
    #[arg(long)]
    pub code: String,

    /// Bot username (a-z, 0-9, _, 3-20 chars).
    #[arg(long)]
    pub username: String,

    /// Overwrite an existing identity file (DANGEROUS — loses the current bot account).
    #[arg(long, default_value_t = false)]
    pub force: bool,
}

#[derive(clap::Args, Debug)]
pub struct RunArgs {
    #[arg(long, env = "LITTLELOVE_BOT_SERVER")]
    pub server: String,

    #[arg(
        long,
        env = "LITTLELOVE_BOT_LLM_URL",
        default_value = "http://localhost:8080/v1"
    )]
    pub llm_url: String,

    #[arg(long, env = "LITTLELOVE_BOT_MODEL", default_value = "local-model")]
    pub model: String,

    #[arg(long, env = "LITTLELOVE_BOT_TEMPERATURE", default_value_t = 0.8)]
    pub temperature: f32,

    #[arg(long, env = "LITTLELOVE_BOT_MAX_TOKENS", default_value_t = 512)]
    pub max_tokens: u32,

    /// Max recent raw turns to inject into the prompt (oldest dropped first).
    #[arg(long, env = "LITTLELOVE_BOT_HISTORY", default_value_t = 20)]
    pub history: usize,

    #[arg(long, env = "LITTLELOVE_BOT_MEMORY_DIR")]
    pub memory_dir: Option<std::path::PathBuf>,

    #[arg(long, env = "LITTLELOVE_BOT_SUMMARY_EVERY", default_value_t = 20)]
    pub summary_every: usize,

    #[arg(
        long,
        env = "LITTLELOVE_BOT_MAX_CONTEXT_CHARS",
        default_value_t = 28_000
    )]
    pub max_context_chars: usize,

    /// Character Card v2/v3 PNG. Mutually exclusive with --system-prompt-file and the env var.
    #[arg(long, conflicts_with_all = ["system_prompt_file"])]
    pub character_card: Option<std::path::PathBuf>,

    #[arg(long)]
    pub system_prompt_file: Option<std::path::PathBuf>,
}
