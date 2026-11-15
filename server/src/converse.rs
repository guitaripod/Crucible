//! Conversations in which the model calls tools: one turn at a time, with what it thought kept apart from what it
//! said, and the probe that shows whether a model can do this at all.

use std::sync::LazyLock;

use regex::Regex;
use serde_json::{json, Value};

use crate::brain::{Brain, BrainError};

/// A tool the model asked to run, with the arguments it gave.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolCall {
    pub id: String,
    pub name: String,
    pub arguments: Value,
}

/// One turn of the model in a tool conversation.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Turn {
    pub content: String,
    pub reasoning: String,
    pub calls: Vec<ToolCall>,
    pub finish: Option<String>,
}

/// What a model showed it can do when probed: call a tool on its own, and think before it answers.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Abilities {
    pub tools: bool,
    pub thinking: bool,
}

static THINK_BLOCK: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?s)<think>(.*?)</think>").expect("think pattern"));

impl Turn {
    /// The message to send back as the model's own turn: what it said and the calls it made, without its thinking.
    pub fn as_message(&self) -> Value {
        let mut message = json!({"role": "assistant", "content": self.content});
        if !self.calls.is_empty() {
            message["tool_calls"] = Value::Array(
                self.calls
                    .iter()
                    .map(|call| json!({"id": call.id, "type": "function", "function": {"name": call.name, "arguments": call.arguments.to_string()}}))
                    .collect(),
            );
        }
        message
    }
}

/// A tool's answer, as the message that goes back to the model.
pub fn tool_result(call: &ToolCall, content: &Value) -> Value {
    json!({"role": "tool", "tool_call_id": call.id, "name": call.name, "content": content.to_string()})
}

/// A tool for the model, in the shape every OpenAI-compatible server reads.
pub fn tool(name: &str, description: &str, parameters: Value) -> Value {
    json!({"type": "function", "function": {"name": name, "description": description, "parameters": parameters}})
}

/// The model's turn from a chat completion. Reasoning arrives as `reasoning_content` (llama.cpp, vLLM, SGLang), as
/// `reasoning` (Ollama, OpenRouter), or inline in `<think>` tags from a template that does not split it out. Arguments
/// arrive as a JSON string or, from some servers, as an object.
pub fn parse_turn(reply: &Value) -> Result<Turn, BrainError> {
    let choice = reply["choices"].get(0).ok_or(BrainError::Shape)?;
    let message = &choice["message"];
    let mut content = message["content"].as_str().unwrap_or("").to_string();
    let mut reasoning = message["reasoning_content"].as_str().or_else(|| message["reasoning"].as_str()).unwrap_or("").to_string();
    if let Some(inline) = THINK_BLOCK.captures(&content) {
        reasoning.push_str(inline[1].trim());
        content = THINK_BLOCK.replace_all(&content, "").trim().to_string();
    }
    let calls = message["tool_calls"]
        .as_array()
        .map(|calls| {
            calls
                .iter()
                .enumerate()
                .filter_map(|(index, call)| {
                    let function = &call["function"];
                    let name = function["name"].as_str()?.trim().to_string();
                    let arguments = match &function["arguments"] {
                        Value::String(text) => serde_json::from_str(text).unwrap_or_else(|_| crate::brain::first_json_object(text).unwrap_or(json!({}))),
                        Value::Object(_) => function["arguments"].clone(),
                        _ => json!({}),
                    };
                    let id = call["id"].as_str().filter(|id| !id.is_empty()).map_or_else(|| format!("call_{index}"), str::to_string);
                    Some(ToolCall { id, name, arguments })
                })
                .collect()
        })
        .unwrap_or_default();
    Ok(Turn {
        content: content.trim().to_string(),
        reasoning: reasoning.trim().to_string(),
        calls,
        finish: choice["finish_reason"].as_str().map(str::to_string),
    })
}

impl Brain {
    /// One turn of a conversation that may call `tools`. `force` makes the model call one of them instead of
    /// answering in words, for the last turn of a budget.
    pub async fn converse(&self, messages: &[Value], tools: &[Value], force: bool, answer_tokens: u32) -> Result<Turn, BrainError> {
        let tokens = answer_tokens + self.thinking_room();
        let reply = self.post_chat(|omitted| omitted.tool_request(&self.model.name, messages, tools, force, tokens)).await?;
        parse_turn(&reply)
    }

    /// Asks the model to use a tool without being made to, which only a model that really calls tools does, and
    /// notes whether it thought first.
    pub async fn abilities(&self) -> Result<Abilities, BrainError> {
        let tools = [tool(
            "look_up",
            "Look up the date of a sports event by its name.",
            json!({"type": "object", "properties": {"event": {"type": "string"}}, "required": ["event"]}),
        )];
        let messages = [
            json!({"role": "system", "content": "You answer questions about sports events. You know nothing yourself: look every event up with the tool."}),
            json!({"role": "user", "content": "When was UFC 300?"}),
        ];
        let turn = self.converse(&messages, &tools, false, 512).await?;
        let called = turn.calls.iter().any(|call| call.name == "look_up" && call.arguments["event"].as_str().is_some_and(|event| event.contains("300")));
        Ok(Abilities { tools: called, thinking: !turn.reasoning.is_empty() })
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::brain::testing::{start, Received};
    use crate::config::Model;

    #[test]
    fn reads_calls_reasoning_and_inline_thinking() {
        let reply = json!({"choices": [{"finish_reason": "tool_calls", "message": {
            "content": "", "reasoning_content": "Search first.",
            "tool_calls": [{"id": "a1", "type": "function", "function": {"name": "web_search", "arguments": "{\"query\":\"UFC 334\"}"}},
                           {"type": "function", "function": {"name": "read_page", "arguments": {"url": "https://ufc.com"}}}]}}]});
        let turn = parse_turn(&reply).unwrap();
        assert_eq!(turn.reasoning, "Search first.");
        assert_eq!(turn.calls[0], ToolCall { id: "a1".into(), name: "web_search".into(), arguments: json!({"query": "UFC 334"}) });
        assert_eq!(turn.calls[1].id, "call_1");
        assert_eq!(turn.calls[1].arguments["url"], "https://ufc.com");
        let inline = parse_turn(&json!({"choices": [{"message": {"content": "<think>Hmm.</think>Done."}}]})).unwrap();
        assert_eq!((inline.reasoning.as_str(), inline.content.as_str()), ("Hmm.", "Done."));
        assert!(parse_turn(&json!({"choices": []})).is_err());
    }

    #[test]
    fn the_models_own_turn_goes_back_without_its_thinking() {
        let turn = Turn {
            content: String::new(),
            reasoning: "secret".into(),
            calls: vec![ToolCall { id: "a".into(), name: "submit".into(), arguments: json!({"x": 1}) }],
            finish: None,
        };
        let message = turn.as_message();
        assert!(!message.to_string().contains("secret"));
        assert_eq!(message["tool_calls"][0]["function"]["arguments"], "{\"x\":1}");
    }

    #[tokio::test]
    async fn the_probe_tells_a_tool_caller_from_a_model_that_only_talks() {
        let caller = start(
            &["bolt"],
            Arc::new(|received: &[Received]| {
                assert_eq!(received.last().unwrap().body["tool_choice"], "auto");
                assert!(received.last().unwrap().body.get("chat_template_kwargs").is_none());
                (
                    200,
                    Vec::new(),
                    json!({"choices": [{"message": {"content": "", "reasoning_content": "Look it up.",
                    "tool_calls": [{"id": "x", "type": "function", "function": {"name": "look_up", "arguments": "{\"event\":\"UFC 300\"}"}}]}}]}),
                )
            }),
        )
        .await;
        let model = |url: &str| Model { url: url.into(), name: "bolt".into(), context: 65_536 };
        assert_eq!(Brain::new(model(&caller.url)).abilities().await.unwrap(), Abilities { tools: true, thinking: true });
        let talker = start(&["bolt"], Arc::new(|_: &[Received]| (200, Vec::new(), json!({"choices": [{"message": {"content": "April 13, 2024."}}]})))).await;
        assert_eq!(Brain::new(model(&talker.url)).abilities().await.unwrap(), Abilities { tools: false, thinking: false });
    }
}
