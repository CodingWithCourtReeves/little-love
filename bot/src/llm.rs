//! OpenAI-compatible chat-completions client. Talks only to private IPs.

use std::time::Duration;

use anyhow::{anyhow, Context, Result};
use serde::{Deserialize, Serialize};

use crate::addr_guard::ensure_url_is_private;

#[derive(Debug, Clone, Serialize)]
pub struct ChatMessage {
    pub role: String,
    pub content: String,
}

pub struct LlmClient {
    base_url: String,
    model: String,
    temperature: f32,
    max_tokens: u32,
    http: reqwest::Client,
}

#[derive(Serialize)]
struct ChatBody<'a> {
    model: &'a str,
    messages: &'a [ChatMessage],
    stream: bool,
    temperature: f32,
    max_tokens: u32,
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<ChatChoice>,
}

#[derive(Deserialize)]
struct ChatChoice {
    message: ChatChoiceMessage,
}

#[derive(Deserialize)]
struct ChatChoiceMessage {
    content: String,
}

impl LlmClient {
    pub fn new(
        base_url: &str,
        model: &str,
        temperature: f32,
        max_tokens: u32,
        timeout: Duration,
    ) -> Result<Self> {
        ensure_url_is_private(base_url)
            .with_context(|| format!("refusing LLM endpoint {base_url}"))?;
        let http = reqwest::Client::builder()
            .timeout(timeout)
            .build()
            .context("reqwest client")?;
        Ok(Self {
            base_url: base_url.trim_end_matches('/').to_string(),
            model: model.to_string(),
            temperature,
            max_tokens,
            http,
        })
    }

    pub async fn chat(&self, messages: &[ChatMessage]) -> Result<String> {
        ensure_url_is_private(&self.base_url)
            .with_context(|| format!("LLM endpoint flipped to non-private: {}", self.base_url))?;
        let body = ChatBody {
            model: &self.model,
            messages,
            stream: false,
            temperature: self.temperature,
            max_tokens: self.max_tokens,
        };
        let url = format!("{}/chat/completions", self.base_url);
        let resp = self
            .http
            .post(&url)
            .json(&body)
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        let status = resp.status();
        if !status.is_success() {
            let text = resp.text().await.unwrap_or_default();
            return Err(anyhow!("LLM {status}: {text}"));
        }
        let body: ChatResponse = resp.json().await.context("decode chat response")?;
        let choice = body
            .choices
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("LLM returned no choices"))?;
        Ok(choice.message.content)
    }
}
