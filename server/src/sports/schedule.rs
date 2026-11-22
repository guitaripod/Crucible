//! When research may run: a week of hours on the server's own clock, Monday first, so the owner keeps the graphics card
//! for games, films or other models at the hours they use it.

use std::fmt;

#[cfg(test)]
use jiff::civil;
use jiff::{ToSpan, ZonedDateTime as Zoned};
use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Every hour of a day, as a day's mask holds them.
pub const WHOLE_DAY: u32 = (1 << 24) - 1;

const DAY_NAMES: [&str; 7] = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"];

/// The hours research may run, one 24-bit mask per weekday from Monday, bit `h` being the hour from `h`:00.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Week(pub [u32; 7]);

impl Week {
    /// A week from the masks the apps send, Monday first; `None` when there are not seven of them, a mask names an hour
    /// past 23, or no hour is chosen at all.
    pub fn from_masks(masks: &[u32]) -> Option<Week> {
        let days: [u32; 7] = masks.try_into().ok()?;
        let week = Week(days);
        (days.iter().all(|mask| *mask <= WHOLE_DAY) && week.hours() > 0).then_some(week)
    }

    pub fn allows(&self, weekday: usize, hour: usize) -> bool {
        self.0[weekday % 7] & (1 << (hour % 24)) != 0
    }

    /// How many hours a week research may run.
    pub fn hours(&self) -> u32 {
        self.0.iter().map(|mask| mask.count_ones()).sum()
    }

    pub fn is_always(&self) -> bool {
        self.0.iter().all(|mask| *mask == WHOLE_DAY)
    }

    pub fn open_at(&self, at: &Zoned) -> bool {
        self.allows(at.weekday().to_monday_zero_offset() as usize, at.hour() as usize)
    }

    /// The next moment after `from` when research may start or must stop, on the hour, within the coming eight days.
    pub fn next_change(&self, from: &Zoned) -> Option<Zoned> {
        let open = self.open_at(from);
        let mut hour = from.with().minute(0).second(0).subsec_nanosecond(0).build().ok()?;
        for _ in 0..(8 * 24 + 2) {
            hour = hour.checked_add(1.hour()).ok()?;
            if self.open_at(&hour) != open {
                return Some(hour);
            }
        }
        None
    }

    /// Reads a week such as `mon-fri 01-07, sat-sun all day` or `daily 22-06`: entries split by commas or semicolons, each
    /// naming days (`mon`, `mon-fri`, `sat+sun`, `daily`, `weekdays`, `weekends`) and one or more hour ranges (`01-07`,
    /// `1:00-7:00`, `22-06`, which runs past midnight into the next day, or `all day`).
    pub fn parse(text: &str) -> Result<Week, String> {
        let mut days = [0u32; 7];
        for entry in text.split([',', ';']).map(str::trim).filter(|entry| !entry.is_empty()) {
            let entry = entry.to_lowercase().replace("all day", "00-24");
            let mut words = entry.split_whitespace();
            let named = words.next().ok_or_else(|| format!("{entry} names no days"))?;
            let chosen = parse_days(named)?;
            let ranges: Vec<&str> = words.collect();
            if ranges.is_empty() {
                return Err(format!("{entry} names no hours, such as 01-07 or all day"));
            }
            for range in ranges {
                let (start, end) = parse_range(range)?;
                let length = if end > start { end - start } else { 24 - start + end };
                for day in &chosen {
                    for step in 0..length {
                        let hour = start + step;
                        days[(day + hour as usize / 24) % 7] |= 1 << (hour % 24);
                    }
                }
            }
        }
        Week::from_masks(&days).ok_or_else(|| "The schedule chooses no hours.".to_string())
    }

    /// The week as `parse` reads it, days with the same hours joined: `mon-fri 01-07, sat-sun 00-24`.
    pub fn spec(&self) -> String {
        let mut entries: Vec<String> = Vec::new();
        let mut day = 0;
        while day < 7 {
            let mask = self.0[day];
            let mut last = day;
            while last + 1 < 7 && self.0[last + 1] == mask {
                last += 1;
            }
            if mask != 0 {
                let days = if day == last { DAY_NAMES[day].to_string() } else { format!("{}-{}", DAY_NAMES[day], DAY_NAMES[last]) };
                let hours: Vec<String> = ranges(mask).into_iter().map(|(start, end)| format!("{start:02}-{end:02}")).collect();
                entries.push(format!("{days} {}", hours.join(" ")));
            }
            day = last + 1;
        }
        entries.join(", ")
    }
}

impl fmt::Display for Week {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.spec())
    }
}

impl Serialize for Week {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.spec())
    }
}

impl<'de> Deserialize<'de> for Week {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let text = String::deserialize(deserializer)?;
        Week::parse(&text).map_err(serde::de::Error::custom)
    }
}

/// The runs of set hours in a day's mask, as (first hour, hour after the last).
fn ranges(mask: u32) -> Vec<(u32, u32)> {
    let mut found = Vec::new();
    let mut hour = 0;
    while hour < 24 {
        if mask & (1 << hour) == 0 {
            hour += 1;
            continue;
        }
        let start = hour;
        while hour < 24 && mask & (1 << hour) != 0 {
            hour += 1;
        }
        found.push((start, hour));
    }
    found
}

fn day_index(name: &str) -> Result<usize, String> {
    let short: String = name.chars().take(3).collect();
    DAY_NAMES.iter().position(|day| *day == short).ok_or_else(|| format!("{name} is not a day such as mon or sat"))
}

fn parse_days(text: &str) -> Result<Vec<usize>, String> {
    match text {
        "daily" | "everyday" | "all" => return Ok((0..7).collect()),
        "weekdays" => return Ok((0..5).collect()),
        "weekends" => return Ok(vec![5, 6]),
        _ => {}
    }
    let mut chosen = Vec::new();
    for part in text.split('+') {
        match part.split_once('-') {
            Some((first, last)) => {
                let (first, last) = (day_index(first)?, day_index(last)?);
                let mut day = first;
                loop {
                    chosen.push(day);
                    if day == last {
                        break;
                    }
                    day = (day + 1) % 7;
                }
            }
            None => chosen.push(day_index(part)?),
        }
    }
    Ok(chosen)
}

fn parse_hour(text: &str) -> Result<u32, String> {
    let hour = text.split_once(':').map_or(text, |(hour, minutes)| if minutes.trim_start_matches('0').is_empty() { hour } else { "x" });
    hour.parse::<u32>().ok().filter(|hour| *hour <= 24).ok_or_else(|| format!("{text} is not a whole hour such as 07 or 07:00"))
}

/// An hour range as (start, end), end 24 for midnight at the end of the day; a range whose end comes before its start
/// runs past midnight.
fn parse_range(text: &str) -> Result<(u32, u32), String> {
    let (start, end) = text.split_once('-').ok_or_else(|| format!("{text} is not an hour range such as 01-07"))?;
    let (start, end) = (parse_hour(start)?, parse_hour(end)?);
    if start == 24 {
        return Err(format!("{text} starts at 24; start at 00 instead"));
    }
    if start == end % 24 && end != 24 {
        return Err(format!("{text} is empty; use 00-24 for the whole day"));
    }
    Ok((start, end))
}

/// The time on the server's clock, in the zone the machine is set to.
pub fn local_now() -> Zoned {
    Zoned::now()
}

/// The server's time zone as people know it, such as Europe/Helsinki, when the machine names one.
pub fn zone_name(at: &Zoned) -> Option<String> {
    at.time_zone().iana_name().map(str::to_string)
}

/// The server clock's offset from UTC now, in seconds.
pub fn utc_offset(at: &Zoned) -> i32 {
    at.offset().seconds()
}

/// A day and hour on the server's clock, for tests.
#[cfg(test)]
fn at(date: civil::Date, hour: i8, zone: &str) -> Zoned {
    date.at(hour, 0, 0, 0).in_tz(zone).unwrap()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_days_and_hours_and_writes_them_back() {
        let week = Week::parse("mon-fri 01-07, sat-sun all day").unwrap();
        assert_eq!(week.0[0], 0b111_1110);
        assert_eq!(week.0[5], WHOLE_DAY);
        assert_eq!(week.hours(), 5 * 6 + 48);
        assert_eq!(week.spec(), "mon-fri 01-07, sat-sun 00-24");
        assert_eq!(Week::parse(&week.spec()).unwrap(), week);
    }

    #[test]
    fn a_range_past_midnight_runs_into_the_next_day_and_sunday_into_monday() {
        let week = Week::parse("sun 22-02").unwrap();
        assert_eq!(week.0[6], (1 << 22) | (1 << 23));
        assert_eq!(week.0[0], 0b11);
        let daily = Week::parse("daily 22:00-06:00").unwrap();
        assert!(daily.allows(2, 23) && daily.allows(3, 5) && !daily.allows(3, 6));
        assert_eq!(daily.spec(), "mon-sun 00-06 22-24");
    }

    #[test]
    fn named_groups_and_lists_of_days() {
        assert_eq!(Week::parse("weekends 10-12").unwrap().0, [0, 0, 0, 0, 0, 0xC00, 0xC00]);
        assert_eq!(Week::parse("mon+wed+fri-sat 0-1").unwrap().0, [1, 0, 1, 0, 1, 1, 0]);
        assert!(Week::parse("daily 00-24").unwrap().is_always());
    }

    #[test]
    fn refuses_what_it_cannot_read() {
        for text in ["", "mon", "funday 01-02", "mon 01", "mon 07-07", "mon 24-02", "mon 01:30-02", "mon 01-25"] {
            assert!(Week::parse(text).is_err(), "{text}");
        }
        assert!(Week::from_masks(&[0; 7]).is_none());
        assert!(Week::from_masks(&[1; 6]).is_none());
        assert!(Week::from_masks(&[1 << 24, 0, 0, 0, 0, 0, 0]).is_none());
    }

    #[test]
    fn finds_when_research_starts_and_stops() {
        let week = Week::parse("mon-fri 01-07").unwrap();
        let friday_noon = at(civil::date(2026, 11, 20), 12, "Europe/Helsinki");
        assert!(!week.open_at(&friday_noon));
        let opens = week.next_change(&friday_noon).unwrap();
        assert_eq!((opens.weekday(), opens.hour()), (jiff::civil::Weekday::Monday, 1));
        let stops = week.next_change(&opens).unwrap();
        assert_eq!((stops.weekday(), stops.hour()), (jiff::civil::Weekday::Monday, 7));
        assert!(Week::parse("daily 00-24").unwrap().next_change(&friday_noon).is_none());
    }

    #[test]
    fn counts_hours_on_the_clock_across_a_change_to_summer_time() {
        let week = Week::parse("sun 04-05").unwrap();
        let before = at(civil::date(2027, 3, 28), 1, "Europe/Helsinki");
        let opens = week.next_change(&before).unwrap();
        assert_eq!(opens.hour(), 4);
        assert_eq!(utc_offset(&opens), 3 * 3600);
    }
}
