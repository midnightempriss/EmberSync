use serde_json::Value;
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub fn canonical_json(value: &Value) -> Vec<u8> {
    serde_json::to_vec(&sort(value)).expect("JSON values are always serializable")
}

pub fn sha256_hex(value: &Value) -> String {
    hex::encode(Sha256::digest(canonical_json(value)))
}

fn sort(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let ordered: BTreeMap<_, _> = object
                .iter()
                .map(|(key, value)| (key.clone(), sort(value)))
                .collect();
            Value::Object(ordered.into_iter().collect())
        }
        Value::Array(values) => Value::Array(values.iter().map(sort).collect()),
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn object_order_does_not_change_hash() {
        let first = serde_json::json!({"b": 2, "a": {"z": 1, "x": 0}});
        let second = serde_json::json!({"a": {"x": 0, "z": 1}, "b": 2});
        assert_eq!(canonical_json(&first), br#"{"a":{"x":0,"z":1},"b":2}"#);
        assert_eq!(sha256_hex(&first), sha256_hex(&second));
    }
}
