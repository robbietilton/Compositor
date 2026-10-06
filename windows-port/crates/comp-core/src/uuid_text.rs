//! UUID fields serialize in uppercase.
//!
//! The macOS app writes `uuidString`, which is uppercase, and its validator compares
//! `imageFile` against `"\(layer.id.uuidString).png"` as strings. A lowercase id would therefore
//! make every package this project saves fail to load in the macOS app, so every UUID that reaches a
//! manifest goes through here. Reading accepts either case, as `UUID(uuidString:)` does.
use serde::{Deserialize, Deserializer, Serializer};
use uuid::Uuid;

/// Formats a UUID the way `uuidString` does.
pub fn to_text(id: Uuid) -> String {
    id.to_string().to_uppercase()
}

pub fn serialize<S: Serializer>(value: &Uuid, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&to_text(*value))
}

pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Uuid, D::Error> {
    let text = String::deserialize(deserializer)?;
    Uuid::parse_str(&text).map_err(serde::de::Error::custom)
}

/// The same, for optional fields.
pub mod optional {
    use super::*;

    pub fn serialize<S: Serializer>(value: &Option<Uuid>, serializer: S) -> Result<S::Ok, S::Error> {
        match value {
            Some(id) => serializer.serialize_some(&to_text(*id)),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Uuid>, D::Error> {
        let text = Option::<String>::deserialize(deserializer)?;
        match text {
            None => Ok(None),
            Some(text) => Uuid::parse_str(&text).map(Some).map_err(serde::de::Error::custom),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_is_uppercase() {
        let id = Uuid::parse_str("6f1d3c2a-0b7e-4e8a-9c4d-2a1b3c4d5e6f").unwrap();
        assert_eq!(to_text(id), "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F");
    }

    #[test]
    fn round_trips_through_json_in_both_cases() {
        let id = Uuid::parse_str("6f1d3c2a-0b7e-4e8a-9c4d-2a1b3c4d5e6f").unwrap();
        let text = serde_json::to_string(&Uppercase(id)).unwrap();
        assert_eq!(text, "\"6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F\"");
        let lower = "\"6f1d3c2a-0b7e-4e8a-9c4d-2a1b3c4d5e6f\"";
        let back: Uppercase = serde_json::from_str(lower).unwrap();
        assert_eq!(back.0, id);
    }

    #[derive(serde::Serialize, serde::Deserialize)]
    struct Uppercase(#[serde(with = "super")] Uuid);
}
