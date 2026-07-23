use serde_json::Value;
use sha2::{Digest, Sha256};

pub fn canonical_json(value: &Value) -> Vec<u8> {
    // The website and protocol use ECMAScript's JSON number formatting and
    // UTF-16 object-key ordering. RFC 8785 (JCS) defines those exact rules;
    // serde_json's ordinary serializer and Rust string ordering do not.
    serde_json_canonicalizer::to_vec(value).expect("JSON values are always serializable")
}

pub fn sha256_hex(value: &Value) -> String {
    hex::encode(Sha256::digest(canonical_json(value)))
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

    #[test]
    fn canonical_json_matches_ecmascript_number_and_utf16_key_rules() {
        let value = serde_json::json!({
            "\u{fffd}": "replacement",
            "\u{1f600}": "astral",
            "numbers": [
                -0.0,
                1e-7,
                1e-6,
                1e15,
                1e16,
                1e20,
                1e21,
                0.03921568766236305,
                83.33333587646484,
                280.0625
            ]
        });
        assert_eq!(
            String::from_utf8(canonical_json(&value)).unwrap(),
            "{\"numbers\":[0,1e-7,0.000001,1000000000000000,10000000000000000,100000000000000000000,1e+21,0.03921568766236305,83.33333587646484,280.0625],\"😀\":\"astral\",\"�\":\"replacement\"}"
        );
    }

    #[test]
    fn canonical_envelope_hash_matches_the_protocol_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../protocol/fixtures/canonical-envelope-v1.json"
        ))
        .unwrap();
        let expected =
            include_str!("../../../protocol/fixtures/canonical-envelope-v1.sha256").trim();
        assert_eq!(sha256_hex(&fixture), expected);
    }
}
