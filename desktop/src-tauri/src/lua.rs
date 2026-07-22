use serde_json::{Map, Number, Value};
use std::collections::BTreeMap;
use thiserror::Error;

pub const MAX_INPUT_BYTES: usize = 64 * 1024 * 1024;
const MAX_DEPTH: usize = 64;
const MAX_NODES: usize = 1_000_000;
const MAX_STRING_BYTES: usize = 4 * 1024 * 1024;

#[derive(Debug, Error, PartialEq)]
pub enum LuaParseError {
    #[error("SavedVariables document exceeds {MAX_INPUT_BYTES} bytes")]
    InputTooLarge,
    #[error("expected {expected} at byte {offset}")]
    Expected {
        expected: &'static str,
        offset: usize,
    },
    #[error("unexpected token at byte {0}")]
    Unexpected(usize),
    #[error("only the EmberSyncDB assignment is accepted")]
    WrongVariable,
    #[error("executable Lua is not accepted")]
    ExecutableCode,
    #[error("table nesting exceeds {MAX_DEPTH}")]
    TooDeep,
    #[error("document has too many values")]
    TooManyNodes,
    #[error("string exceeds {MAX_STRING_BYTES} bytes")]
    StringTooLarge,
    #[error("invalid string escape at byte {0}")]
    InvalidEscape(usize),
    #[error("invalid number at byte {0}")]
    InvalidNumber(usize),
    #[error("duplicate table key {0}")]
    DuplicateKey(String),
    #[error("unsupported table key at byte {0}")]
    UnsupportedKey(usize),
}

#[derive(Debug, Clone, PartialEq)]
enum LuaValue {
    Nil,
    Bool(bool),
    Number(f64),
    String(String),
    Table(Vec<(LuaKey, LuaValue)>),
}

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
enum LuaKey {
    String(String),
    Integer(i64),
}

pub fn parse_ember_sync_db(input: &[u8]) -> Result<Value, LuaParseError> {
    if input.len() > MAX_INPUT_BYTES {
        return Err(LuaParseError::InputTooLarge);
    }
    let text = std::str::from_utf8(input).map_err(|_| LuaParseError::Unexpected(0))?;
    let text = text.strip_prefix('\u{feff}').unwrap_or(text);
    let mut parser = Parser::new(text);
    parser.skip_ws();
    let variable = parser.identifier()?;
    if variable != "EmberSyncDB" {
        return Err(LuaParseError::WrongVariable);
    }
    parser.skip_ws();
    parser.expect_byte(b'=', "=")?;
    let value = parser.value(0)?;
    parser.skip_ws();
    if parser.peek() == Some(b';') {
        parser.bump();
        parser.skip_ws();
    }
    if parser.peek().is_some() {
        return Err(LuaParseError::ExecutableCode);
    }
    Ok(to_json(value))
}

struct Parser<'a> {
    input: &'a [u8],
    offset: usize,
    nodes: usize,
}

impl<'a> Parser<'a> {
    fn new(input: &'a str) -> Self {
        Self {
            input: input.as_bytes(),
            offset: 0,
            nodes: 0,
        }
    }

    fn peek(&self) -> Option<u8> {
        self.input.get(self.offset).copied()
    }
    fn bump(&mut self) -> Option<u8> {
        let value = self.peek()?;
        self.offset += 1;
        Some(value)
    }
    fn skip_ws(&mut self) {
        while matches!(self.peek(), Some(b' ' | b'\t' | b'\r' | b'\n')) {
            self.offset += 1;
        }
    }

    fn expect_byte(&mut self, byte: u8, expected: &'static str) -> Result<(), LuaParseError> {
        if self.bump() == Some(byte) {
            Ok(())
        } else {
            Err(LuaParseError::Expected {
                expected,
                offset: self.offset.saturating_sub(1),
            })
        }
    }

    fn identifier(&mut self) -> Result<String, LuaParseError> {
        let start = self.offset;
        match self.peek() {
            Some(ch) if ch == b'_' || ch.is_ascii_alphabetic() => self.offset += 1,
            _ => {
                return Err(LuaParseError::Expected {
                    expected: "identifier",
                    offset: self.offset,
                })
            }
        }
        while matches!(self.peek(), Some(ch) if ch == b'_' || ch.is_ascii_alphanumeric()) {
            self.offset += 1;
        }
        Ok(String::from_utf8_lossy(&self.input[start..self.offset]).into_owned())
    }

    fn value(&mut self, depth: usize) -> Result<LuaValue, LuaParseError> {
        if depth > MAX_DEPTH {
            return Err(LuaParseError::TooDeep);
        }
        self.nodes += 1;
        if self.nodes > MAX_NODES {
            return Err(LuaParseError::TooManyNodes);
        }
        self.skip_ws();
        match self.peek() {
            Some(b'{') => self.table(depth + 1),
            Some(b'\'' | b'"') => self.string().map(LuaValue::String),
            Some(b'-' | b'0'..=b'9') => self.number().map(LuaValue::Number),
            Some(ch) if ch == b'_' || ch.is_ascii_alphabetic() => {
                let offset = self.offset;
                match self.identifier()?.as_str() {
                    "true" => Ok(LuaValue::Bool(true)),
                    "false" => Ok(LuaValue::Bool(false)),
                    "nil" => Ok(LuaValue::Nil),
                    _ => Err(LuaParseError::ExecutableCode),
                }
                .map_err(|error| match error {
                    LuaParseError::ExecutableCode => {
                        self.offset = offset;
                        LuaParseError::ExecutableCode
                    }
                    other => other,
                })
            }
            _ => Err(LuaParseError::Unexpected(self.offset)),
        }
    }

    fn table(&mut self, depth: usize) -> Result<LuaValue, LuaParseError> {
        self.expect_byte(b'{', "{")?;
        let mut entries = Vec::new();
        let mut seen = BTreeMap::<LuaKey, ()>::new();
        let mut array_index = 1_i64;
        loop {
            self.skip_ws();
            if self.peek() == Some(b'}') {
                self.bump();
                break;
            }
            let (key, value) = if self.peek() == Some(b'[') {
                self.bump();
                self.skip_ws();
                let key_offset = self.offset;
                let key_value = self.value(depth)?;
                let key = match key_value {
                    LuaValue::String(value) => LuaKey::String(value),
                    LuaValue::Number(value)
                        if value.fract() == 0.0
                            && value >= i64::MIN as f64
                            && value <= i64::MAX as f64 =>
                    {
                        LuaKey::Integer(value as i64)
                    }
                    _ => return Err(LuaParseError::UnsupportedKey(key_offset)),
                };
                self.skip_ws();
                self.expect_byte(b']', "]")?;
                self.skip_ws();
                self.expect_byte(b'=', "=")?;
                (key, self.value(depth)?)
            } else if matches!(self.peek(), Some(ch) if ch == b'_' || ch.is_ascii_alphabetic()) {
                let saved = self.offset;
                let identifier = self.identifier()?;
                self.skip_ws();
                if self.peek() == Some(b'=') {
                    self.bump();
                    (LuaKey::String(identifier), self.value(depth)?)
                } else {
                    self.offset = saved;
                    let value = self.value(depth)?;
                    let key = LuaKey::Integer(array_index);
                    array_index += 1;
                    (key, value)
                }
            } else {
                let value = self.value(depth)?;
                let key = LuaKey::Integer(array_index);
                array_index += 1;
                (key, value)
            };
            if seen.insert(key.clone(), ()).is_some() {
                return Err(LuaParseError::DuplicateKey(format_key(&key)));
            }
            entries.push((key, value));
            self.skip_ws();
            match self.peek() {
                Some(b',' | b';') => {
                    self.bump();
                }
                Some(b'}') => {}
                _ => {
                    return Err(LuaParseError::Expected {
                        expected: ", or }",
                        offset: self.offset,
                    })
                }
            }
        }
        Ok(LuaValue::Table(entries))
    }

    fn string(&mut self) -> Result<String, LuaParseError> {
        let quote = self.bump().ok_or(LuaParseError::Unexpected(self.offset))?;
        let mut output = Vec::new();
        loop {
            let byte = self.bump().ok_or(LuaParseError::Expected {
                expected: "closing quote",
                offset: self.offset,
            })?;
            if byte == quote {
                break;
            }
            if byte == b'\n' || byte == b'\r' {
                return Err(LuaParseError::Unexpected(self.offset - 1));
            }
            if byte != b'\\' {
                output.push(byte);
            } else {
                let escape_at = self.offset - 1;
                let escaped = self.bump().ok_or(LuaParseError::InvalidEscape(escape_at))?;
                match escaped {
                    b'a' => output.push(7),
                    b'b' => output.push(8),
                    b'f' => output.push(12),
                    b'n' => output.push(b'\n'),
                    b'r' => output.push(b'\r'),
                    b't' => output.push(b'\t'),
                    b'v' => output.push(11),
                    b'\\' => output.push(b'\\'),
                    b'"' => output.push(b'"'),
                    b'\'' => output.push(b'\''),
                    b'\n' => output.push(b'\n'),
                    b'\r' => {
                        if self.peek() == Some(b'\n') {
                            self.bump();
                        }
                        output.push(b'\n');
                    }
                    b'z' => self.skip_ws(),
                    digit if digit.is_ascii_digit() => {
                        let mut value = u16::from(digit - b'0');
                        for _ in 0..2 {
                            if let Some(next) = self.peek().filter(u8::is_ascii_digit) {
                                value = value * 10 + u16::from(next - b'0');
                                self.bump();
                            } else {
                                break;
                            }
                        }
                        if value > 255 {
                            return Err(LuaParseError::InvalidEscape(escape_at));
                        }
                        output.push(value as u8);
                    }
                    _ => return Err(LuaParseError::InvalidEscape(escape_at)),
                }
            }
            if output.len() > MAX_STRING_BYTES {
                return Err(LuaParseError::StringTooLarge);
            }
        }
        String::from_utf8(output).map_err(|_| LuaParseError::InvalidEscape(self.offset))
    }

    fn number(&mut self) -> Result<f64, LuaParseError> {
        let start = self.offset;
        if self.peek() == Some(b'-') {
            self.bump();
        }
        let mut digits = 0;
        while matches!(self.peek(), Some(ch) if ch.is_ascii_digit()) {
            self.bump();
            digits += 1;
        }
        if self.peek() == Some(b'.') {
            self.bump();
            while matches!(self.peek(), Some(ch) if ch.is_ascii_digit()) {
                self.bump();
                digits += 1;
            }
        }
        if digits == 0 {
            return Err(LuaParseError::InvalidNumber(start));
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.bump();
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.bump();
            }
            let exponent_start = self.offset;
            while matches!(self.peek(), Some(ch) if ch.is_ascii_digit()) {
                self.bump();
            }
            if exponent_start == self.offset {
                return Err(LuaParseError::InvalidNumber(start));
            }
        }
        let value = std::str::from_utf8(&self.input[start..self.offset])
            .ok()
            .and_then(|v| v.parse::<f64>().ok())
            .filter(|v| v.is_finite())
            .ok_or(LuaParseError::InvalidNumber(start))?;
        Ok(value)
    }
}

fn format_key(key: &LuaKey) -> String {
    match key {
        LuaKey::String(value) => value.clone(),
        LuaKey::Integer(value) => value.to_string(),
    }
}

fn to_json(value: LuaValue) -> Value {
    match value {
        LuaValue::Nil => Value::Null,
        LuaValue::Bool(value) => Value::Bool(value),
        LuaValue::Number(value)
            if value.fract() == 0.0 && value >= i64::MIN as f64 && value <= i64::MAX as f64 =>
        {
            Value::Number(Number::from(value as i64))
        }
        LuaValue::Number(value) => Number::from_f64(value)
            .map(Value::Number)
            .unwrap_or(Value::Null),
        LuaValue::String(value) => Value::String(value),
        LuaValue::Table(entries) => table_to_json(entries),
    }
}

fn table_to_json(entries: Vec<(LuaKey, LuaValue)>) -> Value {
    let array_length = entries.len();
    let is_dense_array = array_length > 0 && entries.iter().all(|(key, _)| matches!(key, LuaKey::Integer(value) if *value >= 1 && *value as usize <= array_length))
        && (1..=array_length).all(|expected| entries.iter().any(|(key, _)| *key == LuaKey::Integer(expected as i64)));
    if is_dense_array {
        let mut ordered: Vec<Option<Value>> = vec![None; array_length];
        for (key, value) in entries {
            if let LuaKey::Integer(index) = key {
                ordered[index as usize - 1] = Some(to_json(value));
            }
        }
        return Value::Array(
            ordered
                .into_iter()
                .map(|value| value.unwrap_or(Value::Null))
                .collect(),
        );
    }
    let mut object = Map::new();
    for (key, value) in entries {
        let key = match key {
            LuaKey::String(value) if value.starts_with('#') => format!("#{value}"),
            LuaKey::String(value) => value,
            LuaKey::Integer(value) => format!("#{value}"),
        };
        object.insert(key, to_json(value));
    }
    Value::Object(object)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_saved_variables_literals_without_execution() {
        let input = br#"EmberSyncDB = { ["schemaVersion"] = 1, exports = { main = { guild = { key = "main", name = "Raining Embers", realm = "Dalaran", region = "US" }, values = { [1] = "one", [2] = "two" } } }, enabled = true }"#;
        let value = parse_ember_sync_db(input).unwrap();
        assert_eq!(value["schemaVersion"], 1);
        assert_eq!(value["exports"]["main"]["guild"]["realm"], "Dalaran");
        assert_eq!(value["exports"]["main"]["values"][1], "two");
    }

    #[test]
    fn handles_unicode_escapes_sparse_and_empty_tables() {
        let input = "\u{feff} EmberSyncDB = { name = \"Arìa\", quote = \"a\\\"b\", sparse = { [2] = true }, empty = {}, bytes = \"A\\065\" };";
        let value = parse_ember_sync_db(input.as_bytes()).unwrap();
        assert_eq!(value["name"], "Arìa");
        assert_eq!(value["quote"], "a\"b");
        assert_eq!(value["sparse"]["#2"], true);
        assert_eq!(value["empty"], serde_json::json!({}));
        assert_eq!(value["bytes"], "AA");
    }

    #[test]
    fn rejects_code_trailing_statements_and_duplicate_keys() {
        assert_eq!(
            parse_ember_sync_db(b"print('owned')"),
            Err(LuaParseError::WrongVariable)
        );
        assert_eq!(
            parse_ember_sync_db(b"EmberSyncDB = setmetatable({}, {})"),
            Err(LuaParseError::ExecutableCode)
        );
        assert_eq!(
            parse_ember_sync_db(b"EmberSyncDB = {}; os.execute('x')"),
            Err(LuaParseError::ExecutableCode)
        );
        assert!(matches!(
            parse_ember_sync_db(b"EmberSyncDB = { a = 1, a = 2 }"),
            Err(LuaParseError::DuplicateKey(_))
        ));
    }

    #[test]
    fn rejects_excessive_depth_and_input_size() {
        let deep = format!(
            "EmberSyncDB = {}{}",
            "{".repeat(MAX_DEPTH + 2),
            "}".repeat(MAX_DEPTH + 2)
        );
        assert_eq!(
            parse_ember_sync_db(deep.as_bytes()),
            Err(LuaParseError::TooDeep)
        );
        assert_eq!(
            parse_ember_sync_db(&vec![b' '; MAX_INPUT_BYTES + 1]),
            Err(LuaParseError::InputTooLarge)
        );
    }
}
