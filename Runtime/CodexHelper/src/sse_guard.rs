//! Validate every raw Responses event before the upstream decoder discards fields.
use serde_json::Value;

pub(crate) const MAX_BODY: usize = 4 * 1024 * 1024;
pub(crate) const MAX_OUTPUT: usize = 512 * 1024;

#[derive(Default)]
pub(crate) struct Guard { pending: Vec<u8>, pub(crate) final_text: Option<String>, failed: bool }
impl Guard {
    fn healthy(v: &Value, terminal: bool, queued_allowed: bool) -> Result<(), ()> {
        if !v.is_object() { return Err(()); }
        for field in ["error", "incomplete_details", "safety_buffering"] {
            if v.get(field).is_some_and(|value| !value.is_null()) { return Err(()); }
        }
        if let Some(status) = v.get("status").filter(|value| !value.is_null()) {
            let status = status.as_str().ok_or(())?;
            if !(status == "completed" || (!terminal && (status == "in_progress" || (queued_allowed && status == "queued")))) { return Err(()); }
        }
        Ok(())
    }
    fn ordinary_metadata(v: &Value) -> Result<(), ()> {
        // The official decoder accepts header strings and arrays of strings.
        // Inspect every array entry, not only the first value it consumes.
        fn headers(v: Option<&Value>) -> Result<(), ()> {
            let Some(value) = v.filter(|value| !value.is_null()) else { return Ok(()); };
            for value in value.as_object().ok_or(())?.values() {
                match value {
                    Value::String(_) => {}
                    Value::Array(values) if !values.is_empty() && values.iter().all(Value::is_string) => {}
                    _ => return Err(()),
                }
            }
            Ok(())
        }
        // Verification, moderation, safety buffering and future metadata
        // require explicit handling before they can be accepted by this client.
        if let Some(metadata) = v.get("metadata").filter(|value| !value.is_null()) {
            if !metadata.as_object().is_some_and(|object| object.is_empty()) { return Err(()); }
        }
        headers(v.get("headers"))?;
        if let Some(response) = v.get("response") { headers(response.get("headers"))?; }
        Ok(())
    }
    fn part(v: &Value) -> Result<&str, ()> {
        if v.get("type").and_then(Value::as_str) != Some("output_text") { return Err(()); }
        let text = v.get("text").and_then(Value::as_str).ok_or(())?;
        if text.len() > MAX_OUTPUT { return Err(()); }
        Ok(text)
    }
    fn item(v: &Value, terminal: bool) -> Result<Option<String>, ()> {
        Self::healthy(v, terminal, false)?;
        match v.get("type").and_then(Value::as_str) {
            Some("reasoning") => Ok(None),
            Some("message") if v.get("role").and_then(Value::as_str) == Some("assistant") => {
                // Official MessagePhase applies to assistant messages only. An
                // absent phase remains compatible with older providers, but
                // progress commentary is never part of the translated result.
                let commentary = match v.get("phase") {
                    None | Some(Value::Null) => false,
                    Some(Value::String(phase)) if phase == "final_answer" => false,
                    Some(Value::String(phase)) if phase == "commentary" => true,
                    _ => return Err(()),
                };
                let mut text = String::new();
                for c in v.get("content").and_then(Value::as_array).ok_or(())? {
                    text.push_str(Self::part(c)?);
                    if text.len() > MAX_OUTPUT { return Err(()); }
                }
                Ok((!commentary).then_some(text))
            }
            _ => Err(()),
        }
    }
    fn snapshot(v: &Value, terminal: bool) -> Result<Option<String>, ()> {
        Self::healthy(v, terminal, true)?;
        let Some(output) = v.get("output") else { return Ok(None); };
        let mut text = String::new();
        for item in output.as_array().ok_or(())? {
            if let Some(part) = Self::item(item, terminal)? { text.push_str(&part); }
            if text.len() > MAX_OUTPUT { return Err(()); }
        }
        Ok(Some(text))
    }
    fn frame(&mut self, frame: &[u8]) -> Result<(), ()> {
        let text = std::str::from_utf8(frame).map_err(|_| ())?;
        let data = text.lines().filter_map(|l|l.strip_prefix("data:").map(str::trim_start)).collect::<Vec<_>>().join("\n");
        if data.is_empty() { return Ok(()); }
        let v: Value = serde_json::from_str(&data).map_err(|_| ())?;
        let kind = v.get("type").and_then(Value::as_str).ok_or(())?;
        // Safety buffering can attach to any event, including a text delta.
        // Never let a later completed snapshot erase an earlier restriction.
        Self::healthy(&v, kind == "response.completed", true)?;
        // Every response snapshot is inspected before the official parser can discard fields.
        let snapshot = if let Some(response) = v.get("response") {
            Self::snapshot(response, kind == "response.completed")?
        } else { None };
        match kind {
            "response.metadata" => { Self::ordinary_metadata(&v)?; }
            "response.output_item.added" => { Self::item(v.get("item").ok_or(())?, false)?; }
            "response.output_item.done" => { Self::item(v.get("item").ok_or(())?, true)?; }
            "response.content_part.added" | "response.content_part.done" => { Self::part(v.get("part").ok_or(())?)?; }
            "response.completed" => {
                if v.get("response").and_then(|response| response.get("status")).and_then(Value::as_str) != Some("completed") { return Err(()); }
                if self.final_text.is_some() { return Err(()); }
                let result = snapshot.ok_or(())?;
                if result.trim().is_empty() { return Err(()); }
                self.final_text = Some(result);
            }
            "response.created" | "response.in_progress" | "response.output_text.delta" | "response.output_text.done" |
            "response.reasoning_text.delta" | "response.reasoning_text.done" |
            "response.reasoning_summary_text.delta" | "response.reasoning_summary_text.done" |
            "response.reasoning_summary_part.added" | "response.reasoning_summary_part.done" => {}
            // Includes refusal, failed/incomplete, every tool event, and unknown event kinds.
            _ => return Err(()),
        }
        Ok(())
    }
    pub(crate) fn bytes(&mut self, chunk: &[u8]) -> Result<(), ()> {
        if self.failed { return Err(()); }
        self.pending.extend_from_slice(chunk);
        if self.pending.len() > MAX_BODY { return Err(()); }
        loop {
            let lf = self.pending.windows(2).position(|x| x == b"\n\n").map(|i|(i,2));
            let crlf = self.pending.windows(4).position(|x| x == b"\r\n\r\n").map(|i|(i,4));
            let split = match (lf,crlf) { (Some(a),Some(b)) => Some(if a.0 < b.0 {a} else {b}), (a,b) => a.or(b) };
            let Some((at,size)) = split else {break};
            let frame = self.pending.drain(..at+size).collect::<Vec<_>>();
            if self.frame(&frame).is_err() {self.failed=true;return Err(());}
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn message(text: &str, phase: Option<Value>) -> Value {
        let mut item = json!({"type":"message", "role":"assistant", "status":"completed",
            "content":[{"type":"output_text", "text":text}]});
        if let Some(phase) = phase { item["phase"] = phase; }
        item
    }

    fn complete(output: Vec<Value>) -> Result<Option<String>, ()> {
        let event = json!({"type":"response.completed", "response":{"status":"completed", "output":output}});
        let mut guard = Guard::default();
        guard.bytes(format!("data: {event}\n\n").as_bytes())?;
        Ok(guard.final_text)
    }

    #[test]
    fn commentary_is_validated_but_excluded_from_final_translation() {
        assert_eq!(complete(vec![
            message("Translating now.", Some(json!("commentary"))),
            message("你好", Some(json!("final_answer"))),
        ]).unwrap().as_deref(), Some("你好"));
    }

    #[test]
    fn commentary_without_a_nonempty_final_answer_is_incomplete() {
        assert!(complete(vec![message("Translating now.", Some(json!("commentary")))]).is_err());
        assert!(complete(vec![message("Translating now.", Some(json!("commentary"))),
            message(" \n", Some(json!("final_answer")))]).is_err());
    }

    #[test]
    fn unknown_or_malformed_message_phases_are_rejected() {
        for phase in [json!("unknown"), json!(""), json!(false), json!(0), json!([]), json!({})] {
            assert!(complete(vec![message("你好", Some(phase))]).is_err());
        }
    }

    #[test]
    fn missing_or_null_phase_preserves_legacy_compatibility() {
        for phase in [None, Some(Value::Null)] {
            assert_eq!(complete(vec![message("你好", phase)]).unwrap().as_deref(), Some("你好"));
        }
    }

    #[test]
    fn commentary_cannot_hide_refusal_or_tool_content() {
        for content in [json!({"type":"refusal", "refusal":"No"}),
            json!({"type":"function_call", "name":"unexpected"})] {
            let mut item = message("", Some(json!("commentary")));
            item["content"] = json!([content]);
            assert!(complete(vec![item, message("你好", Some(json!("final_answer")))]).is_err());
        }
    }

    #[test]
    fn message_phase_checks_do_not_apply_to_reasoning_items() {
        assert_eq!(complete(vec![json!({"type":"reasoning", "phase":"other", "status":"completed"}),
            message("你好", Some(json!("final_answer")))]).unwrap().as_deref(), Some("你好"));
    }

    fn after_event(event: Value) -> Result<Option<String>, ()> {
        let mut guard = Guard::default();
        guard.bytes(format!("data: {event}\n\n").as_bytes())?;
        let final_event = json!({"type":"response.completed", "response":{"status":"completed",
            "output":[message("你好", Some(json!("final_answer")))]}});
        guard.bytes(format!("data: {final_event}\n\n").as_bytes())?;
        Ok(guard.final_text)
    }

    #[test]
    fn ordinary_headers_metadata_preserves_completed_translation() {
        for metadata in [None, Some(Value::Null), Some(json!({}))] {
            let mut event = json!({"type":"response.metadata", "sequence_number":1,
                "headers":{"openai-model":"constructed-model", "x-codex-turn-state":["constructed-state"]}});
            if let Some(metadata) = metadata { event["metadata"] = metadata; }
            assert_eq!(after_event(event).unwrap().as_deref(), Some("你好"));
        }
        assert!(after_event(json!({"type":"response.metadata", "metadata":{}})).is_ok());
    }

    #[test]
    fn malformed_metadata_headers_are_rejected() {
        for headers in [json!([]), json!(false), json!({"x":0}), json!({"x":null}),
            json!({"x":[]}), json!({"x":["valid",false]}), json!({"x":[["nested"]]})] {
            assert!(after_event(json!({"type":"response.metadata", "headers":headers})).is_err());
        }
        assert!(after_event(json!({"type":"response.metadata", "response":{"headers":{"x":false}}})).is_err());
    }

    #[test]
    fn safety_recommendations_and_unknown_metadata_are_rejected() {
        for metadata in [json!({"openai_verification_recommendation":["trusted_access_for_cyber"]}),
            json!({"openai_chatgpt_moderation_metadata":{"presentation":"inline"}}),
            json!({"type":"safety_buffering"}), json!({"unknown":true}), json!([]), json!("")] {
            assert!(after_event(json!({"type":"response.metadata", "metadata":metadata})).is_err());
        }
    }

    #[test]
    fn top_level_restrictions_are_rejected_on_every_event() {
        for kind in ["response.metadata", "response.created", "response.output_text.delta"] {
            for field in ["safety_buffering", "error", "incomplete_details"] {
                let mut event = json!({"type":kind});
                event[field] = json!({"constructed":true});
                assert!(after_event(event).is_err());
            }
        }
    }

    #[test]
    fn ordinary_metadata_still_validates_its_response_snapshot() {
        for response in [json!({"status":"incomplete"}), json!({"error":{}}),
            json!({"incomplete_details":{}}), json!({"output":[{"type":"function_call"}]}),
            json!({"output":[{"type":"message", "role":"assistant", "content":[{"type":"refusal"}]}]})] {
            assert!(after_event(json!({"type":"response.metadata", "headers":{}, "response":response})).is_err());
        }
    }
}
