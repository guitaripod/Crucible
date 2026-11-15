//! Writing a checked record into Plex: every field locked so Plex's own agents leave it, artwork uploaded as bytes so
//! Plex keeps its own copy, and nothing written over a change the owner made by hand. The files are never touched.

use super::record::Desired;
use super::web::Web;
use crate::plex::{Artwork, Item, Plex, PlexError, TAG_LIST};

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
    for (tag, now, earlier) in [
        ("genre", &desired.genres, before.map(|before| &before.genres)),
        ("collection", &desired.collections, before.map(|before| &before.collections)),
        ("actor", &desired.cast, before.map(|before| &before.cast)),
    ] {
        for (index, value) in now.iter().enumerate() {
            pairs.push((format!("{tag}[{index}].tag.tag"), value.clone()));
        }
        let gone: Vec<&String> = earlier.map(|earlier| earlier.iter().filter(|value| !now.contains(value)).collect()).unwrap_or_default();
        if !gone.is_empty() {
            pairs.push((format!("{tag}[].tag.tag-"), gone.iter().map(|value| value.as_str()).collect::<Vec<_>>().join(&TAG_LIST.to_string())));
        }
        if !now.is_empty() || !gone.is_empty() {
            pairs.push((format!("{tag}.locked"), "1".to_string()));
        }
    }
    pairs
}

/// What Plex showed for an item before research first wrote to it, kept so the owner can take research back.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct Original {
    pub title: String,
    pub title_sort: String,
    pub summary: String,
    pub tagline: String,
    pub studio: String,
    pub date: String,
    pub year: i64,
    pub genres: Vec<String>,
    pub collections: Vec<String>,
    pub cast: Vec<String>,
    /// The poster and background Plex showed, by the key Plex selects them with.
    pub poster: Option<String>,
    pub background: Option<String>,
}

impl Original {
    /// The item as Plex shows it now.
    pub fn of(item: &Item) -> Original {
        Original {
            title: item.title.clone(),
            title_sort: item.title_sort.clone().unwrap_or_default(),
            summary: item.summary.clone().unwrap_or_default(),
            tagline: item.tagline.clone().unwrap_or_default(),
            studio: item.studio.clone().unwrap_or_default(),
            date: item.originally_available_at.as_deref().map(|date| date.get(..10).unwrap_or(date).to_string()).unwrap_or_default(),
            year: item.year.unwrap_or(0),
            genres: item.genres.iter().map(|tag| tag.tag.clone()).collect(),
            collections: item.collections.iter().map(|tag| tag.tag.clone()).collect(),
            cast: item.roles.iter().map(|role| role.tag.clone()).collect(),
            poster: None,
            background: None,
        }
    }

    /// What Plex's own agent shows for a file in an Other Videos library that nothing was ever written to: its name
    /// without the extension, and nothing else.
    pub fn of_file(file_name: &str) -> Original {
        let title = file_name.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(file_name).to_string();
        Original { title, ..Original::default() }
    }
}

/// The edit parameters that take research back from an item Plex shows as `now`. A field returns to what Plex showed
/// before and is unlocked only while it still holds what research wrote, so a change the owner made since stays; the
/// genres, collections and cast research added go. With nothing known of what research wrote (a write Plex refused
/// part of, from before writes were kept), the fields locked now are taken as research's.
pub fn undo_pairs(original: &Original, written: Option<&Desired>, now: &Item) -> Vec<(String, String)> {
    let locked = |name: &str| now.locks.iter().any(|lock| lock.locked && lock.name == name);
    let still = |name: &str, value: Option<&str>, wrote: Option<&str>| match written {
        Some(_) => wrote.is_some_and(|wrote| value.unwrap_or("").trim() == wrote.trim()),
        None => locked(name),
    };
    let date = now.originally_available_at.as_deref().map(|date| date.get(..10).unwrap_or(date));
    let year = now.year.filter(|year| *year > 0).map(|year| year.to_string());
    let wrote_year = written.map(|written| if written.year > 0 { written.year.to_string() } else { String::new() });
    let fields = [
        ("title", Some(now.title.as_str()), written.map(|written| written.title.as_str()), original.title.clone()),
        (
            "titleSort",
            now.title_sort.as_deref().or(written.map(|written| written.title_sort.as_str())),
            written.map(|written| written.title_sort.as_str()),
            original.title_sort.clone(),
        ),
        ("summary", now.summary.as_deref(), written.map(|written| written.summary.as_str()), original.summary.clone()),
        ("tagline", now.tagline.as_deref(), written.map(|written| written.tagline.as_str()), original.tagline.clone()),
        ("studio", now.studio.as_deref(), written.map(|written| written.studio.as_str()), original.studio.clone()),
        ("originallyAvailableAt", date, written.map(|written| written.date.as_str()), original.date.clone()),
        ("year", year.as_deref(), wrote_year.as_deref(), if original.year > 0 { original.year.to_string() } else { String::new() }),
    ];
    let mut pairs = Vec::new();
    for (name, value, wrote, before) in fields {
        if still(name, value, wrote) {
            pairs.push((format!("{name}.value"), before));
            pairs.push((format!("{name}.locked"), "0".to_string()));
        }
    }
    let Some(written) = written else { return pairs };
    let names = |tags: &mut dyn Iterator<Item = &String>| tags.cloned().collect::<Vec<String>>();
    for (tag, before, wrote, present) in [
        ("genre", &original.genres, &written.genres, names(&mut now.genres.iter().map(|tag| &tag.tag))),
        ("collection", &original.collections, &written.collections, names(&mut now.collections.iter().map(|tag| &tag.tag))),
        ("actor", &original.cast, &written.cast, names(&mut now.roles.iter().map(|role| &role.tag))),
    ] {
        let present: Vec<&String> = present.iter().collect();
        let added: Vec<&String> = wrote.iter().filter(|value| !before.contains(value) && present.contains(value)).collect();
        if !added.is_empty() {
            pairs.push((format!("{tag}[].tag.tag-"), added.iter().map(|value| value.as_str()).collect::<Vec<_>>().join(&TAG_LIST.to_string())));
        }
        let left: Vec<&&String> = present.iter().filter(|value| !added.contains(value)).collect();
        if left.iter().all(|value| before.contains(value)) {
            pairs.push((format!("{tag}.locked"), "0".to_string()));
        }
    }
    pairs
}

/// The address of the poster or background research wrote.
pub fn artwork_of(written: &Desired, kind: Artwork) -> Option<&String> {
    match kind {
        Artwork::Poster => written.poster.as_ref(),
        Artwork::Background => written.background.as_ref(),
    }
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

/// Writes `desired` to the item and uploads its artwork when it is new. Artwork the owner set in Plex is left alone,
/// and artwork that cannot be fetched, is not an image or that Plex turns away is skipped with a note: once the fields
/// are written the write counts, so what research wrote is always known.
pub async fn apply(plex: &Plex, web: &Web, token: &str, section: &str, item: &Item, desired: &Desired, before: Option<&Desired>) -> Result<Outcome, PlexError> {
    let rating_key = item.rating_key.as_str();
    plex.edit(section, rating_key, &edit_pairs(desired, before), token).await?;
    let mut outcome = Outcome::default();
    for kind in [Artwork::Poster, Artwork::Background] {
        let Some(address) = artwork_of(desired, kind) else { continue };
        let earlier = before.and_then(|before| artwork_of(before, kind));
        if earlier == Some(address) {
            continue;
        }
        if earlier.is_none() && item.locks.iter().any(|lock| lock.locked && kind.lock_field().strip_suffix(".locked") == Some(lock.name.as_str())) {
            outcome.notes.push(format!("the {} you set in Plex is kept", kind.noun()));
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
        let uploaded = match plex.upload_artwork(rating_key, kind, bytes, token).await {
            Ok(()) => plex.edit(section, rating_key, &[(kind.lock_field().to_string(), "1".to_string())], token).await,
            Err(error) => Err(error),
        };
        match uploaded {
            Ok(()) => match kind {
                Artwork::Poster => outcome.poster = true,
                Artwork::Background => outcome.background = true,
            },
            Err(error) => outcome.notes.push(format!("Plex did not take the {}: {error}", kind.noun())),
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
            cast: Vec::new(),
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
        let mut fewer = desired();
        fewer.genres.clear();
        let mut two = desired();
        two.genres.push("Boxing, Pro".into());
        assert!(edit_pairs(&fewer, Some(&two)).contains(&("genre[].tag.tag-".into(), format!("Mixed Martial Arts{TAG_LIST}Boxing, Pro"))));
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

    /// The item as Plex shows it right after research wrote `written`, with the original genre kept beside it.
    fn as_written(written: &Desired) -> Item {
        let tags = |names: &[String]| names.iter().map(|name| crate::plex::Tag { tag: name.clone() }).collect::<Vec<_>>();
        let lock = |name: &str| crate::plex::FieldLock { name: name.into(), locked: true };
        Item {
            title: written.title.clone(),
            title_sort: Some(written.title_sort.clone()),
            summary: Some(written.summary.clone()),
            tagline: Some(written.tagline.clone()),
            studio: Some(written.studio.clone()),
            originally_available_at: Some(written.date.clone()),
            year: Some(written.year.into()),
            genres: tags(&written.genres),
            collections: tags(&written.collections),
            roles: written.cast.iter().map(|name| crate::plex::Role { tag: name.clone(), role: None }).collect(),
            locks: ["title", "titleSort", "summary", "genre"].into_iter().map(lock).collect(),
            ..Item::default()
        }
    }

    #[test]
    fn taking_research_back_restores_and_unlocks_and_removes_what_it_added() {
        let original = Original { title: "UFC 334 Prelims 1080p WEB-DL H264-FBB".into(), genres: vec!["Sports".into()], ..Original::default() };
        let mut written = desired();
        written.genres.push("Sports".into());
        written.cast = vec!["Ciryl Gane".into()];
        let pairs = undo_pairs(&original, Some(&written), &as_written(&written));
        let get = |name: &str| pairs.iter().find(|(key, _)| key == name).map(|(_, value)| value.as_str());
        assert_eq!(get("title.value"), Some("UFC 334 Prelims 1080p WEB-DL H264-FBB"));
        assert_eq!(get("title.locked"), Some("0"));
        assert_eq!(get("summary.value"), Some(""));
        assert_eq!(get("year.value"), Some(""));
        assert_eq!(get("genre[].tag.tag-"), Some("Mixed Martial Arts"));
        assert_eq!(get("genre.locked"), Some("0"));
        assert_eq!(get("collection[].tag.tag-"), Some("UFC 334: Gane vs. Hokit"));
        assert_eq!(get("actor[].tag.tag-"), Some("Ciryl Gane"));
        assert_eq!(Original::of_file("UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4").title, "UFC 334 Prelims 1080p WEB-DL H264-FBB");
    }

    #[test]
    fn taking_research_back_keeps_what_the_owner_changed_since() {
        let original = Original { title: "fight.mkv".into(), ..Original::default() };
        let written = desired();
        let mut now = as_written(&written);
        now.title = "My own title".into();
        now.summary = Some("My words.".into());
        now.genres.push(crate::plex::Tag { tag: "Favourites".into() });
        let pairs = undo_pairs(&original, Some(&written), &now);
        let names: Vec<&str> = pairs.iter().map(|(name, _)| name.as_str()).collect();
        assert!(!names.contains(&"title.value") && !names.contains(&"summary.value"));
        assert!(names.contains(&"studio.value") && names.contains(&"titleSort.value"));
        assert!(pairs.contains(&("genre[].tag.tag-".into(), "Mixed Martial Arts".into())));
        assert!(!names.contains(&"genre.locked"));
    }

    #[test]
    fn without_a_kept_write_only_locked_fields_are_taken_back() {
        let mut now = as_written(&desired());
        now.locks.retain(|lock| lock.name == "title");
        let pairs = undo_pairs(&Original::of_file("fight.mkv"), None, &now);
        assert_eq!(pairs, vec![("title.value".to_string(), "fight".to_string()), ("title.locked".to_string(), "0".to_string())]);
    }

    #[test]
    fn knows_images_by_their_bytes() {
        assert!(is_image(&[0xFF, 0xD8, 0xFF, 0xE0]));
        assert!(is_image(b"\x89PNG\r\n\x1a\nrest"));
        assert!(is_image(b"RIFF\x00\x00\x00\x00WEBPVP8 "));
        assert!(!is_image(b"<html>"));
    }
}
