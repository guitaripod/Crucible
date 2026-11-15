//! What the apps show of a researched file: where it stands and, once researched, the event as the research found it.

use serde_json::{json, Value};

use super::record::{domain, Record};
use super::release::Release;
use crate::store::SportsItem;

/// One item as `GET /sports` lists it.
pub fn item_view(item: &SportsItem) -> Value {
    let record: Option<Record> = item.record.as_deref().and_then(|text| serde_json::from_str(text).ok());
    let detail = record.map(|record| {
        let lineup: Vec<Value> = record
            .bouts_for(record.part.as_deref())
            .into_iter()
            .filter(|bout| bout.matchup.contains(" vs. "))
            .map(|bout| json!({"matchup": bout.matchup, "detail": bout.detail}))
            .collect();
        let mut sources: Vec<String> = Vec::new();
        for source in record.sources.iter().filter_map(|source| domain(source)) {
            if !sources.contains(&source) {
                sources.push(source);
            }
        }
        json!({
            "event": record.event_title(),
            "part": record.part,
            "date": record.date,
            "venue": record.venue,
            "city": record.city,
            "headline": record.headline,
            "league": record.league,
            "sport": record.sport,
            "summary": record.summary,
            "lineup": lineup,
            "sources": sources,
            "posterUrl": record.poster_url,
        })
    });
    json!({
        "ratingKey": item.rating_key,
        "section": item.section,
        "file": item.file,
        "fileName": Release::read(&item.file).file_name,
        "state": item.state,
        "title": item.title,
        "note": item.note,
        "tries": item.tries,
        "nextTry": item.next_try,
        "updated": item.updated,
        "seconds": measured(item.seconds),
        "searches": measured(item.searches),
        "reads": measured(item.reads),
        "detail": detail,
    })
}

/// A count of research effort, or null for a file researched before the server counted it.
fn measured(count: i64) -> Value {
    if count == crate::store::UNMEASURED {
        Value::Null
    } else {
        json!(count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::sports::record::Bout;

    #[test]
    fn shows_the_event_this_file_holds_without_its_other_parts() {
        let record = Record {
            identified: true,
            league: "UFC".into(),
            sport: "Mixed Martial Arts".into(),
            event: "UFC 334: Gane vs. Hokit".into(),
            event_number: Some("UFC 334".into()),
            part: Some("Prelims".into()),
            date: "2026-11-14".into(),
            venue: "Madison Square Garden".into(),
            headline: "Gane vs. Hokit".into(),
            lineup: vec![
                Bout { matchup: "Ciryl Gane vs. Josh Hokit".into(), detail: "Heavyweight".into(), part: Some("Main card".into()) },
                Bout { matchup: "Stephen Thompson vs. Charles Radtke".into(), detail: "Welterweight".into(), part: Some("Prelims".into()) },
            ],
            sources: vec!["https://www.ufc.com/event/ufc-334".into(), "https://ufc.com/news".into(), "https://en.wikipedia.org/wiki/UFC_334".into()],
            ..Record::default()
        };
        let item = SportsItem {
            rating_key: "21417".into(),
            section: "4".into(),
            file: "/mnt/stuff2/Sports/x/UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4".into(),
            state: "matched".into(),
            title: "UFC 334: Gane vs. Hokit · Prelims".into(),
            record: serde_json::to_string(&record).ok(),
            applied: None,
            note: String::new(),
            tries: 0,
            next_try: 0,
            updated: 1,
            seconds: 23,
            searches: 1,
            reads: 2,
        };
        let view = item_view(&item);
        assert_eq!(view["fileName"], "UFC 334 Prelims 1080p WEB-DL H264-FBB.mp4");
        assert_eq!(view["detail"]["event"], "UFC 334: Gane vs. Hokit");
        assert_eq!(view["detail"]["lineup"].as_array().unwrap().len(), 1);
        assert_eq!(view["detail"]["sources"], json!(["ufc.com", "en.wikipedia.org"]));
        assert_eq!(view["seconds"], 23);
        let unmeasured = SportsItem { seconds: crate::store::UNMEASURED, searches: crate::store::UNMEASURED, reads: crate::store::UNMEASURED, ..item.clone() };
        assert!(item_view(&unmeasured)["seconds"].is_null() && item_view(&unmeasured)["reads"].is_null());
        assert!(item_view(&SportsItem { record: None, ..item }).get("detail").is_some_and(Value::is_null));
    }
}
