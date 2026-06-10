use base64::{engine::general_purpose::STANDARD as B64, Engine};
use littlelove_bot::character_card::{parse_png, CardData};

fn make_png_with_chunk(keyword: &str, value: &str) -> Vec<u8> {
    use png::{text_metadata::ITXtChunk, Encoder};
    let mut bytes: Vec<u8> = Vec::new();
    {
        let mut enc = Encoder::new(&mut bytes, 2, 2);
        enc.set_color(png::ColorType::Grayscale);
        enc.set_depth(png::BitDepth::Eight);
        let chunk = ITXtChunk::new(keyword.to_string(), value.to_string());
        enc.add_itxt_chunk(chunk.keyword.clone(), chunk.get_text().unwrap())
            .unwrap();
        let mut w = enc.write_header().unwrap();
        w.write_image_data(&[0u8; 4]).unwrap();
    }
    bytes
}

#[test]
fn parses_v2_card() {
    let json = serde_json::json!({
        "spec": "chara_card_v2",
        "spec_version": "2.0",
        "data": {
            "name": "Aria",
            "description": "a soft-spoken assistant",
            "personality": "patient, curious",
            "scenario": "in a quiet room",
            "system_prompt": "",
            "creator": "test",
            "character_version": "0.1"
        }
    });
    let value = B64.encode(serde_json::to_vec(&json).unwrap());
    let png_bytes = make_png_with_chunk("chara", &value);

    let card = parse_png(&png_bytes).expect("parse v2");
    let data: &CardData = &card.data;
    assert_eq!(data.name, "Aria");
    assert_eq!(data.personality, "patient, curious");
}

#[test]
fn parses_v3_card() {
    let json = serde_json::json!({
        "spec": "chara_card_v3",
        "data": { "name": "Iris", "description": "v3 example", "personality": "",
                  "scenario": "", "system_prompt": "You are Iris." }
    });
    let value = B64.encode(serde_json::to_vec(&json).unwrap());
    let png_bytes = make_png_with_chunk("ccv3", &value);

    let card = parse_png(&png_bytes).expect("parse v3");
    assert_eq!(card.data.name, "Iris");
    assert_eq!(card.data.system_prompt, "You are Iris.");
}

#[test]
fn rejects_png_with_no_card_chunk() {
    let png_bytes = make_png_with_chunk("Comment", "not a card");
    let err = parse_png(&png_bytes).unwrap_err();
    assert!(format!("{err}").contains("no ccv3 or chara"));
}
