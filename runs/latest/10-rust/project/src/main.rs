use serde_json::Value;
use std::cmp::Ordering;
use std::env;
use std::process::{Command, ExitCode};

#[derive(Clone)]
struct Summary {
    user_id: Value,
    completed: i64,
    missed: i64,
}

fn fail(message: impl AsRef<str>) -> Result<(), String> {
    eprintln!("{}", message.as_ref());
    Err(String::new())
}

fn value_to_string(value: &Value) -> String {
    match value {
        Value::Null => String::new(),
        Value::Bool(true) => "true".to_string(),
        Value::Bool(false) => "false".to_string(),
        Value::Number(n) => {
            let raw = n.to_string();
            if raw.contains(['.', 'e', 'E']) {
                raw.to_lowercase()
            } else if let Ok(v) = raw.parse::<i128>() {
                v.to_string()
            } else {
                raw
            }
        }
        Value::String(s) => s.clone(),
        Value::Array(items) => {
            let rendered = items.iter().map(value_to_string).collect::<Vec<_>>();
            format!("[{}]", rendered.join(", "))
        }
        Value::Object(map) => {
            let rendered = map
                .iter()
                .map(|(key, value)| format!("{}={}", key, value_to_string(value)))
                .collect::<Vec<_>>();
            format!("{{{}}}", rendered.join(", "))
        }
    }
}

fn object_lookup<'a>(key: &str, value: &'a Value) -> &'a Value {
    static NULL: Value = Value::Null;
    match value {
        Value::Object(map) => map.get(key).unwrap_or(&NULL),
        _ => &NULL,
    }
}

fn truthy(value: &Value) -> bool {
    match value {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => {
            let raw = n.to_string();
            if raw.contains(['.', 'e', 'E']) {
                raw.parse::<f64>().unwrap_or(0.0) != 0.0
            } else {
                raw.parse::<i128>().unwrap_or(0) != 0
            }
        }
        _ => !value_to_string(value).is_empty(),
    }
}

fn all_digits(value: &str) -> bool {
    value.bytes().all(|ch| ch.is_ascii_digit())
}

fn looks_date_only(value: &str) -> bool {
    value.len() == 10
        && all_digits(&value[0..4])
        && &value[4..5] == "-"
        && all_digits(&value[5..7])
        && &value[7..8] == "-"
        && all_digits(&value[8..10])
}

fn leap_year(year: i64) -> bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap_year(year) => 29,
        2 => 28,
        _ => 0,
    }
}

fn parse_zone_hours(zone: &str) -> f64 {
    if zone.len() != 5 {
        return 0.0;
    }
    let sign_byte = zone.as_bytes()[0];
    if sign_byte != b'+' && sign_byte != b'-' {
        return 0.0;
    }
    if !all_digits(&zone[1..5]) {
        return 0.0;
    }
    let sign = if sign_byte == b'+' { 1.0 } else { -1.0 };
    let hours = zone[1..3].parse::<i64>().unwrap_or(0) as f64;
    let minutes = zone[3..5].parse::<i64>().unwrap_or(0) as f64;
    -(sign * (hours + minutes / 60.0))
}

fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let mut y = year;
    let m = month;
    if m <= 2 {
        y -= 1;
    }
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = m + if m > 2 { -3 } else { 9 };
    let doy = (153 * mp + 2).div_euclid(5) + day - 1;
    let doe = yoe * 365 + yoe.div_euclid(4) - yoe.div_euclid(100) + doy;
    era * 146097 + doe - 719468
}

fn date_to_time(value: &str, zone_hours: f64) -> Result<i64, String> {
    if !looks_date_only(value) {
        return fail(format!(
            "parsing time \"{}\" as \"2006-01-02\": cannot parse \"{}\" as \"2006\"",
            value, value
        ))
        .map(|_| 0);
    }

    let year = value[0..4].parse::<i64>().unwrap();
    let month = value[5..7].parse::<i64>().unwrap();
    let day = value[8..10].parse::<i64>().unwrap();

    if !(1..=9999).contains(&year) {
        return fail(format!("year {} is out of range", year)).map(|_| 0);
    }
    if !(1..=12).contains(&month) {
        return fail("month must be in 1..12").map(|_| 0);
    }
    if day < 1 || day > days_in_month(year, month) {
        return fail(format!("parsing time \"{}\": day out of range", value)).map(|_| 0);
    }

    Ok(days_from_civil(year, month, day) * 86_400 + (zone_hours * 3600.0) as i64)
}

fn local_start_of_today() -> Result<i64, String> {
    let output = Command::new("date")
        .arg("+%Y-%m-%dT00:00:00%z")
        .output()
        .map_err(|err| err.to_string())?;
    let text = String::from_utf8_lossy(&output.stdout);
    let trimmed = text.trim_matches(['\n', '\r', ' ', '\t']);
    let date = if trimmed.len() >= 10 {
        &trimmed[0..10]
    } else {
        "1970-01-01"
    };
    let zone = if trimmed.len() >= 24 {
        &trimmed[19..24]
    } else {
        "+0000"
    };
    date_to_time(date, parse_zone_hours(zone))
}

fn fetch_url(url: &str) -> Result<String, String> {
    let response = reqwest::blocking::get(url).map_err(|err| err.to_string())?;
    let status = response.status();
    if !status.is_success() {
        return fail(format!("bad status: {}", status.as_u16())).map(|_| String::new());
    }
    response.text().map_err(|err| err.to_string())
}

fn compare_json_values(left: &Value, right: &Value) -> Ordering {
    if let (Value::Number(ln), Value::Number(rn)) = (left, right) {
        let left_raw = ln.to_string();
        let right_raw = rn.to_string();
        let left_value = left_raw.parse::<f64>().unwrap_or(0.0);
        let right_value = right_raw.parse::<f64>().unwrap_or(0.0);
        return left_value
            .partial_cmp(&right_value)
            .unwrap_or(Ordering::Equal);
    }

    value_to_string(left).cmp(&value_to_string(right))
}

fn summarize(today: i64, todos: &[Value]) -> Result<Vec<Summary>, String> {
    let mut summaries: Vec<Summary> = Vec::new();

    for todo in todos {
        let user_id = object_lookup("userId", todo);
        let key = value_to_string(user_id);
        let found = summaries
            .iter()
            .position(|summary| value_to_string(&summary.user_id) == key);
        let index = match found {
            Some(index) => index,
            None => {
                summaries.push(Summary {
                    user_id: user_id.clone(),
                    completed: 0,
                    missed: 0,
                });
                summaries.len() - 1
            }
        };

        if truthy(object_lookup("completed", todo)) {
            summaries[index].completed += 1;
        } else {
            let due_text = value_to_string(object_lookup("dueDate", todo));
            let due = date_to_time(&due_text, 0.0)?;
            if due < today {
                summaries[index].missed += 1;
            }
        }
    }

    summaries.sort_by(|left, right| {
        right
            .completed
            .cmp(&left.completed)
            .then_with(|| right.missed.cmp(&left.missed))
            .then_with(|| compare_json_values(&left.user_id, &right.user_id))
    });
    Ok(summaries)
}

fn write_padded(out: &mut String, text: &str, width: usize) {
    out.push_str(text);
    if text.len() < width {
        out.push_str(&" ".repeat(width - text.len()));
    }
}

fn run(args: &[String]) -> Result<u8, String> {
    if args.len() != 2 {
        eprintln!("usage: ./run.sh <url>");
        return Ok(2);
    }

    let body = fetch_url(&args[1])?;
    let value: Value = serde_json::from_str(&body).map_err(|err| {
        eprintln!("{}", err);
        String::new()
    })?;
    let todos = match value {
        Value::Array(items) => items,
        _ => {
            fail("expected JSON array")?;
            Vec::new()
        }
    };

    let rows = summarize(local_start_of_today()?, &todos)?;
    let mut out = String::from("USER  COMPLETED  MISSED\n");
    for row in rows {
        write_padded(&mut out, &value_to_string(&row.user_id), 5);
        out.push(' ');
        write_padded(&mut out, &row.completed.to_string(), 10);
        out.push_str(&format!(" {}\n", row.missed));
    }
    print!("{}", out);
    Ok(0)
}

fn main() -> ExitCode {
    let args = env::args().collect::<Vec<_>>();
    match run(&args) {
        Ok(code) => ExitCode::from(code),
        Err(err) => {
            if !err.is_empty() {
                eprintln!("{}", err);
            }
            ExitCode::from(1)
        }
    }
}
