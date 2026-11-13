//! How often to patrol. The CLI decides when to run (`familiar tick`) and owns the defaults;
//! the app only checks and saves what the settings page sends.
use serde_json::{Map, Value};

use crate::{familiar, update_config};

/// Keys in config.json, shared with the CLI's `Config`.
const KEYS: [&str; 7] = ["scanMode", "times", "intervalMinutes", "startHour", "endHour", "weekdays", "meetingScans"];

/// "8:00" → "08:00". The launchd tick runs every 5 minutes, so any minute is fine.
fn time(text: &str) -> Option<String> {
    let (h, m) = text.trim().split_once(':')?;
    if !(1..=2).contains(&h.len()) || m.len() != 2 { return None; }
    let (h, m): (u32, u32) = (h.parse().ok()?, m.parse().ok()?);
    (h < 24 && m < 60).then(|| format!("{h:02}:{m:02}"))
}

fn number(fields: &Map<String, Value>, key: &str, range: std::ops::RangeInclusive<u64>, what: &str) -> Result<u64, String> {
    fields.get(key).and_then(Value::as_u64).filter(|n| range.contains(n)).ok_or_else(|| format!("{what}が正しくありません"))
}

pub fn check(fields: &Map<String, Value>) -> Result<Map<String, Value>, String> {
    let mode = fields.get("mode").and_then(Value::as_str).filter(|m| ["interval", "times"].contains(m)).ok_or("見回り方が正しくありません")?;
    let mut times: Vec<String> = fields.get("times").and_then(Value::as_array).ok_or("時刻が正しくありません")?
        .iter().map(|t| t.as_str().and_then(time).ok_or_else(|| format!("時刻 {t} を読めません。8:00 のように書きます")))
        .collect::<Result<_, _>>()?;
    times.sort();
    times.dedup();
    if mode == "times" && times.is_empty() { return Err("時刻を 1 つ以上入れてください".into()); }
    let interval = number(fields, "intervalMinutes", 5..=720, "間隔")?;
    let start = number(fields, "startHour", 0..=23, "始まりの時刻")?;
    let end = number(fields, "endHour", 1..=24, "終わりの時刻")?;
    if start >= end { return Err("終わりは始まりより後にしてください".into()); }
    let mut weekdays: Vec<u64> = fields.get("weekdays").and_then(Value::as_array).ok_or("曜日が正しくありません")?
        .iter().map(|d| d.as_u64().filter(|d| (1..=7).contains(d)).ok_or("曜日が正しくありません")).collect::<Result<_, _>>()?;
    weekdays.sort();
    weekdays.dedup();
    if weekdays.is_empty() { return Err("曜日を 1 つ以上選んでください".into()); }
    let meetings = fields.get("meetingScans").and_then(Value::as_bool).ok_or("会議の前後の設定が正しくありません")?;
    let values: [Value; 7] = [mode.into(), times.into(), interval.into(), start.into(), end.into(), weekdays.into(), meetings.into()];
    Ok(KEYS.iter().map(|k| k.to_string()).zip(values).collect())
}

/// Returns the schedule as the CLI now reads it.
#[tauri::command]
pub async fn set_schedule(fields: Map<String, Value>) -> Result<String, String> {
    let saved = check(&fields)?;
    update_config(|config| config.extend(saved))?;
    familiar(vec!["schedule".into()]).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn fields(v: Value) -> Map<String, Value> {
        let mut base = json!({ "mode": "times", "times": ["8:00"], "intervalMinutes": 30, "startHour": 9, "endHour": 20, "weekdays": [2, 3, 4, 5, 6], "meetingScans": true });
        base.as_object_mut().unwrap().extend(v.as_object().unwrap().clone());
        base.as_object().unwrap().clone()
    }

    #[test]
    fn times_are_tidied_and_checked() {
        let saved = check(&fields(json!({ "times": ["13:30", "8:00", "08:00"], "weekdays": [7, 1, 1] }))).unwrap();
        assert_eq!(saved["times"], json!(["08:00", "13:30"]));
        assert_eq!(saved["weekdays"], json!([1, 7]));
        assert_eq!(saved["scanMode"], json!("times"));
        for bad in [json!({ "times": ["25:00"] }), json!({ "times": ["8:000"] }), json!({ "times": [] }), json!({ "weekdays": [] }),
                    json!({ "startHour": 20, "endHour": 9 }), json!({ "intervalMinutes": 1 }), json!({ "mode": "hourly" })] {
            assert!(check(&fields(bad.clone())).is_err(), "{bad}");
        }
        // 間隔で見回るときは、時刻が空でもよい
        assert!(check(&fields(json!({ "mode": "interval", "times": [] }))).is_ok());
    }
}
