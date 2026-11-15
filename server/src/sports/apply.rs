//! Writing a checked record into Plex: every field locked so Plex's own agents leave it, artwork uploaded as bytes so
//! Plex keeps its own copy, and nothing written over a change the owner made by hand. The files are never touched.

use super::record::Desired;
use super::web::Web;
use crate::plex::{Artwork, Item, Plex, PlexError};

/// The edit parameters that write `desired` and lock it, removing the genres and collections an earlier write added
/// that `desired` no longer has.
pub fn edit_pairs(desired: &Desired, before: Option<&Desired>) -> Vec<(String, String)> {
    let mut pairs = Vec::new();
    let mut field = |name: &str, value: &str| {
        pairs.push((format!("{name}.value"), value.to_string()));
        pairs.push((format!("{name}.locked"), "1".to_string()));
    };
    field("title", &desired.title);
    field("titleSort", &desired.title_sort);
    field("summary", &desired.summary);
    field("tagline", &desired.tagline);
    field("studio", &desired.studio);
    if !desired.date.is_empty() {
        field("originallyAvailableAt", &desired.date);
    }
    if desired.year > 0 {
        field("year", &desired.year.to_string());
    }
    for (tag, now, earlier) in
        [("genre", &desired.genres, before.map(|before| &before.genres)), ("collection", &desired.collections, before.map(|before| &before.collections))]
    {
        for (index, value) in now.iter().enumerate() {
            pairs.push((format!("{tag}[{index}].tag.tag"), value.clone()));
        }
        let gone: Vec<&String> = earlier.map(|earlier| earlier.iter().filter(|value| !now.contains(value)).collect()).unwrap_or_default();
        if !gone.is_empty() {
            pairs.push((format!("{tag}[].tag.tag-"), gone.iter().map(|value| value.as_str()).collect::<Vec<_>>().join(",")));
        }
        if !now.is_empty() || !gone.is_empty() {
            pairs.push((format!("{tag}.locked"), "1".to_string()));
        }
    }
    pairs
}

/// Whether the item in Plex differs from `written` in a field this server writes: the owner changed it by hand when it
/// differs both from what was written last and from what would be written now.
pub fn edited_by_owner(item: &Item, written: &Desired) -> bool {
    let differs = |now: Option<&str>, written: &str| !written.is_empty() && now.is_some_and(|now| now.trim() != written.trim());
    differs(Some(item.title.as_str()), &written.title)
        || differs(item.summary.as_deref(), &written.summary)
        || differs(item.title_sort.as_deref(), &written.title_sort)
        || differs(item.originally_available_at.as_deref().map(|date| date.get(..10).unwrap_or(date)), &written.date)
        || differs(item.studio.as_deref(), &written.studio)
        || differs(item.tagline.as_deref(), &written.tagline)
}

/// Whether bytes are an image Plex can show: JPEG, PNG or WebP.
pub fn is_image(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xFF, 0xD8, 0xFF])
        || bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        || (bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP")
}

/// What applying a record did.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub poster: bool,
    pub background: bool,
    pub notes: Vec<String>,
}

/// Writes `desired` to the item and uploads its artwork when it is new. Artwork that cannot be fetched or is not an
/// image is skipped with a note; the fields are written regardless.
pub async fn apply(
    plex: &Plex,
    web: &Web,
    token: &str,
    section: &str,
    rating_key: &str,
    desired: &Desired,
    before: Option<&Desired>,
) -> Result<Outcome, PlexError> {
    plex.edit(section, rating_key, &edit_pairs(desired, before), token).await?;
    let mut outcome = Outcome::default();
    for (kind, address, earlier) in [
        (Artwork::Poster, &desired.poster, before.and_then(|before| before.poster.as_ref())),
        (Artwork::Background, &desired.background, before.and_then(|before| before.background.as_ref())),
    ] {
        let Some(address) = address else { continue };
        if earlier == Some(address) {
            continue;
        }
        let bytes = match web.fetch(address).await {
            Ok((_, _, bytes)) if is_image(&bytes) => bytes,
            Ok(_) => {
                outcome.notes.push(format!("{address} is not a JPEG, PNG or WebP image"));
                continue;
            }
            Err(error) => {
                outcome.notes.push(format!("artwork not fetched: {error}"));
                continue;
            }
        };
        plex.upload_artwork(rating_key, kind, bytes, token).await?;
        plex.edit(section, rating_key, &[(kind.lock_field().to_string(), "1".to_string())], token).await?;
        match kind {
            Artwork::Poster => outcome.poster = true,
            Artwork::Background => outcome.background = true,
        }
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn desired() -> Desired {
        Desired {
            title: "UFC 334: Gane vs. Hokit · Prelims".into(),
            title_sort: "UFC 2026-11-14 2 UFC 334: Gane vs. Hokit".into(),
            summary: "Two heavyweights.".into(),
            tagline: "Gane vs. Hokit".into(),
            studio: "UFC".into(),
            date: "2026-11-14".into(),
            year: 2026,
            genres: vec!["Mixed Martial Arts".into()],
            collections: vec!["UFC 334: Gane vs. Hokit".into()],
            poster: None,
            background: None,
        }
    }

    #[test]
    fn writes_and_locks_every_field_and_removes_what_it_added_before() {
        let pairs = edit_pairs(&desired(), None);
        let get = |name: &str| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str());
        assert_eq!(get("title.value"), Some("UFC 334: Gane vs. Hokit · Prelims"));
        assert_eq!(get("title.locked"), Some("1"));
        assert_eq!(get("originallyAvailableAt.value"), Some("2026-11-14"));
        assert_eq!(get("year.value"), Some("2026"));
        assert_eq!(get("genre[0].tag.tag"), Some("Mixed Martial Arts"));
        assert_eq!(get("collection[0].tag.tag"), Some("UFC 334: Gane vs. Hokit"));
        assert_eq!(get("collection.locked"), Some("1"));
        let mut lone = desired();
        lone.collections.clear();
        let removing = edit_pairs(&lone, Some(&desired()));
        assert!(removing.contains(&("collection[].tag.tag-".into(), "UFC 334: Gane vs. Hokit".into())));
        assert!(removing.contains(&("collection.locked".into(), "1".into())));
        assert!(!edit_pairs(&lone, None).iter().any(|(key, _)| key.starts_with("collection")));
    }

    #[test]
    fn a_hand_edit_makes_the_item_the_owners() {
        let applied = desired();
        let mut item =
            Item { title: applied.title.clone(), summary: Some(applied.summary.clone()), title_sort: Some(applied.title_sort.clone()), ..Item::default() };
        assert!(!edited_by_owner(&item, &applied));
        item.title = "My own title".into();
        assert!(edited_by_owner(&item, &applied));
    }

    #[test]
    fn knows_images_by_their_bytes() {
        assert!(is_image(&[0xFF, 0xD8, 0xFF, 0xE0]));
        assert!(is_image(b"\x89PNG\r\n\x1a\nrest"));
        assert!(is_image(b"RIFF\x00\x00\x00\x00WEBPVP8 "));
        assert!(!is_image(b"<html>"));
    }
}
