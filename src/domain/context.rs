//! I/O-free prompt budgeting. Estimates are deliberately weighted for UTF-8 text;
//! the model's tokenizer remains the authority for its actual context limit.
use anyhow::{ensure, Result};
use serde_json::Value;

#[derive(Clone, Copy, Debug)]
pub struct Budget {
    pub context_tokens: usize,
    pub output_tokens: usize,
}

impl Default for Budget {
    fn default() -> Self {
        Self {
            context_tokens: 8192,
            output_tokens: 1024,
        }
    }
}

impl Budget {
    pub fn new(context_tokens: usize, output_tokens: usize) -> Result<Self> {
        ensure!(
            (2048..=131072).contains(&context_tokens),
            "context must be between 2048 and 131072 tokens"
        );
        ensure!(
            output_tokens >= 128 && output_tokens <= context_tokens / 2,
            "output budget must be between 128 and half the context window"
        );
        Ok(Self {
            context_tokens,
            output_tokens,
        })
    }

    pub fn prompt_tokens(self) -> usize {
        self.context_tokens.saturating_sub(self.output_tokens + 256)
    }
}

fn estimate(text: &str) -> usize {
    let ascii = text.chars().filter(char::is_ascii).count();
    let unicode = text.chars().filter(|c| !c.is_ascii()).count();
    // Weighted estimate, not a tokenizer: reserve more room for CJK text than ASCII.
    ascii.div_ceil(3) + unicode * 2
}

pub fn prompt_cost(messages: &[Value], tools: &[Value]) -> usize {
    messages
        .iter()
        .map(|m| estimate(&m.to_string()) + 32)
        .sum::<usize>()
        + tools
            .iter()
            .map(|t| estimate(&t.to_string()) + 32)
            .sum::<usize>()
}

const OMITTED: &str = "\nEarlier completed conversation turns were omitted to fit the context window. Ask for missing details rather than assuming them.";
const TRUNCATED: &str = "\n[Tool output shortened to fit the context window. Read the relevant file range or rerun a narrower query for omitted details.]";

pub fn fit(messages: &mut Vec<Value>, tools: &[Value], budget: Budget) -> Result<()> {
    let limit = budget.prompt_tokens();
    while prompt_cost(messages, tools) > limit {
        // Drop only whole completed turns. Never leave an orphan tool result.
        let users: Vec<_> = messages
            .iter()
            .enumerate()
            .filter(|(_, m)| m["role"] == "user")
            .map(|(i, _)| i)
            .collect();
        if users.len() <= 1 {
            break;
        }
        messages.drain(1..users[1]);
        if let Some(system) = messages[0]["content"].as_str() {
            if !system.contains(OMITTED) {
                messages[0]["content"] = format!("{system}{OMITTED}").into();
            }
        }
    }
    while prompt_cost(messages, tools) > limit {
        let largest = messages
            .iter()
            .enumerate()
            .filter(|(_, m)| m["role"] == "tool")
            .filter_map(|(i, m)| m["content"].as_str().map(|s| (i, s.len())))
            .filter(|(_, len)| *len > 512)
            .max_by_key(|(_, len)| *len);
        let Some((index, len)) = largest else {
            break;
        };
        let original = messages[index]["content"].as_str().unwrap();
        let text = original.strip_suffix(TRUNCATED).unwrap_or(original);
        let mut end = (len / 2).max(256).min(text.len());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        messages[index]["content"] = format!("{}{TRUNCATED}", &text[..end]).into();
    }
    ensure!(prompt_cost(messages, tools) <= limit,
        "the current request, tool arguments, and required schemas exceed the context budget; shorten the request or increase USIX_CONTEXT_TOKENS");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn discards_completed_turns_and_preserves_current_tool_pairs() {
        let mut messages = vec![
            json!({"role":"system","content":"policy"}),
            json!({"role":"user","content":"old request"}),
            json!({"role":"assistant","content":"old answer".repeat(1000)}),
            json!({"role":"user","content":"latest exact request"}),
            json!({"role":"assistant","tool_calls":[{"id":"call_1","function":{"name":"read_file","arguments":{"path":"README.md"}}}]}),
            json!({"role":"tool","tool_call_id":"call_1","content":"한글😀".repeat(3000)}),
        ];
        let call = messages[4].clone();
        fit(&mut messages, &[], Budget::new(2048, 256).unwrap()).unwrap();
        assert_eq!(messages[1]["content"], "latest exact request");
        assert_eq!(messages[2], call);
        assert_eq!(messages[3]["tool_call_id"], "call_1");
        assert!(messages[3]["content"]
            .as_str()
            .unwrap()
            .ends_with(TRUNCATED));
        assert!(prompt_cost(&messages, &[]) <= 1536);
    }

    #[test]
    fn never_shortens_user_constraints_or_pending_arguments() {
        let request = "preserve this constraint ".repeat(2000);
        let mut messages = vec![
            json!({"role":"system","content":"policy"}),
            json!({"role":"user","content":request}),
        ];
        assert!(fit(&mut messages, &[], Budget::default()).is_err());
        assert_eq!(messages[1]["content"], request);
    }
}
