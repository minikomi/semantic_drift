use serde_json::{Number, Value};
use std::cmp::Ordering;
use std::env;
use std::fmt::Write as _;
use std::io::{self, Write};

#[derive(Debug)]
enum AppError {
    BadStatus { status: u16, reason: Option<&'static str> },
    ExpectedJsonArray,
    MissingKey(&'static str),
    BadDate(String),
    RequestFailed(String),
}

#[derive(Clone)]
struct Summary {
    user_id: Value,
    key: String,
    completed: i64,
    missed: i64,
}

fn main() {
    let mut args = env::args();
    let _program = args.next();
    let Some(url) = args.next() else {
        eprint!("usage: todo-summary <todos-url>\n");
        std::process::exit(1);
    };
    if args.next().is_some() {
        eprint!("usage: todo-summary <todos-url>\n");
        std::process::exit(1);
    }

    if let Err(err) = run(&url) {
        match err {
            AppError::BadStatus { status, reason } => {
                if let Some(reason) = reason {
                    eprintln!("bad status: {status} {reason}");
                } else {
                    eprintln!("bad status: {status}");
                }
            }
            AppError::ExpectedJsonArray => eprintln!("expected JSON array"),
            AppError::MissingKey(key) => eprintln!("key '{key}' not found"),
            AppError::BadDate(value) => {
                eprintln!(
                    "parsing time \"{value}\" as \"2006-01-02\": cannot parse \"{value}\" as \"2006\""
                );
            }
            AppError::RequestFailed(message) => eprintln!("{message}"),
        }
        std::process::exit(1);
    }
}

fn run(url: &str) -> Result<(), AppError> {
    let response = http_get(url)?;

    if response.status < 200 || response.status >= 300 {
        return Err(AppError::BadStatus {
            status: response.status,
            reason: reason_phrase(response.status),
        });
    }

    let todos: Value =
        serde_json::from_slice(&response.body).map_err(|err| AppError::RequestFailed(err.to_string()))?;

    let today = local_midnight_now();
    let mut rows = fold_todos(today, &todos)?;
    rows.sort_by(summary_cmp);

    print!("USER  COMPLETED  MISSED\n");
    for row in rows {
        let user = display_value(&row.user_id);
        pad_right_stdout(5, &user)?;
        print!(" ");
        pad_right_stdout(10, &row.completed.to_string())?;
        println!(" {}", row.missed);
    }

    Ok(())
}

struct HttpResponse {
    body: Vec<u8>,
    status: u16,
}

fn http_get(url: &str) -> Result<HttpResponse, AppError> {
    let parsed = reqwest::Url::parse(url).map_err(|err| AppError::RequestFailed(err.to_string()))?;
    let response = reqwest::blocking::get(parsed).map_err(|err| AppError::RequestFailed(err.to_string()))?;
    let status = response.status().as_u16();
    let body = response
        .bytes()
        .map_err(|err| AppError::RequestFailed(err.to_string()))?
        .to_vec();
    Ok(HttpResponse { body, status })
}

fn reason_phrase(status: u16) -> Option<&'static str> {
    match status {
        400 => Some("Bad Request"),
        401 => Some("Unauthorized"),
        402 => Some("Payment Required"),
        403 => Some("Forbidden"),
        404 => Some("Not Found"),
        405 => Some("Method Not Allowed"),
        406 => Some("Not Acceptable"),
        407 => Some("Proxy Authentication Required"),
        408 => Some("Request Timeout"),
        409 => Some("Conflict"),
        410 => Some("Gone"),
        411 => Some("Length Required"),
        412 => Some("Precondition Failed"),
        413 => Some("Payload Too Large"),
        414 => Some("URI Too Long"),
        415 => Some("Unsupported Media Type"),
        416 => Some("Range Not Satisfiable"),
        417 => Some("Expectation Failed"),
        421 => Some("Misdirected Request"),
        426 => Some("Upgrade Required"),
        429 => Some("Too Many Requests"),
        500 => Some("Internal Server Error"),
        501 => Some("Not Implemented"),
        502 => Some("Bad Gateway"),
        503 => Some("Service Unavailable"),
        504 => Some("Gateway Timeout"),
        505 => Some("HTTP Version Not Supported"),
        _ => None,
    }
}

fn fold_todos(today: i64, todos: &Value) -> Result<Vec<Summary>, AppError> {
    let Value::Array(items) = todos else {
        return Err(AppError::ExpectedJsonArray);
    };

    let mut rows: Vec<Summary> = Vec::new();
    let mut keys: std::collections::HashMap<String, usize> = std::collections::HashMap::new();

    for todo in items {
        let user_id = required(todo, "userId")?;
        let completed = required(todo, "completed")?;
        let due_date = required(todo, "dueDate")?;
        let key = json_key(user_id);

        let index = if let Some(index) = keys.get(&key) {
            *index
        } else {
            let index = rows.len();
            keys.insert(key.clone(), index);
            rows.push(Summary {
                user_id: user_id.clone(),
                key,
                completed: 0,
                missed: 0,
            });
            index
        };

        let row = &mut rows[index];
        if as_boolean(completed) {
            row.completed += 1;
        } else {
            let text = display_value(due_date);
            let due = parse_date_only_in_local_time(&text)?;
            if due < today {
                row.missed += 1;
            }
        }
    }

    Ok(rows)
}

fn required<'a>(todo: &'a Value, field: &'static str) -> Result<&'a Value, AppError> {
    let Value::Object(map) = todo else {
        return Err(AppError::MissingKey(field));
    };
    map.get(field).ok_or(AppError::MissingKey(field))
}

fn as_boolean(value: &Value) -> bool {
    match value {
        Value::Bool(value) => *value,
        Value::String(value) => value == "true",
        Value::Number(value) => number_is_one(value),
        _ => false,
    }
}

fn number_is_one(value: &Number) -> bool {
    value.as_i64() == Some(1) || value.as_u64() == Some(1) || value.as_f64() == Some(1.0)
}

fn display_value(value: &Value) -> String {
    match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => display_number(value),
        Value::Bool(value) => value.to_string(),
        Value::Null => String::new(),
        _ => json_key(value),
    }
}

fn display_number(value: &Number) -> String {
    if let Some(n) = value.as_i64() {
        n.to_string()
    } else if let Some(n) = value.as_u64() {
        n.to_string()
    } else if let Some(n) = value.as_f64() {
        if n.is_finite() && n.trunc() == n {
            (n as i64).to_string()
        } else {
            n.to_string()
        }
    } else {
        value.to_string()
    }
}

fn json_key(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

fn parse_date_only_in_local_time(value: &str) -> Result<i64, AppError> {
    let bytes = value.as_bytes();
    if bytes.len() != 10 || bytes[4] != b'-' || bytes[7] != b'-' {
        return Err(AppError::BadDate(value.to_string()));
    }
    for (idx, ch) in bytes.iter().enumerate() {
        if idx == 4 || idx == 7 {
            continue;
        }
        if !ch.is_ascii_digit() {
            return Err(AppError::BadDate(value.to_string()));
        }
    }

    let year: i32 = value[0..4].parse().map_err(|_| AppError::BadDate(value.to_string()))?;
    let month: i32 = value[5..7].parse().map_err(|_| AppError::BadDate(value.to_string()))?;
    let day: i32 = value[8..10].parse().map_err(|_| AppError::BadDate(value.to_string()))?;

    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    tm.tm_year = year - 1900;
    tm.tm_mon = month - 1;
    tm.tm_mday = day;
    tm.tm_isdst = -1;

    let timestamp = unsafe { libc::mktime(&mut tm) };
    if timestamp == -1 || tm.tm_year != year - 1900 || tm.tm_mon != month - 1 || tm.tm_mday != day {
        return Err(AppError::BadDate(value.to_string()));
    }

    Ok(timestamp as i64)
}

fn local_midnight_now() -> i64 {
    let mut now = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe {
        libc::localtime_r(&mut now, &mut tm);
    }
    tm.tm_sec = 0;
    tm.tm_min = 0;
    tm.tm_hour = 0;
    tm.tm_isdst = -1;
    unsafe { libc::mktime(&mut tm) as i64 }
}

fn pad_right_stdout(width: usize, value: &str) -> Result<(), AppError> {
    print!("{value}");
    if value.len() < width {
        let mut padding = String::new();
        for _ in 0..(width - value.len()) {
            padding.write_char(' ').unwrap();
        }
        print!("{padding}");
    }
    io::stdout()
        .flush()
        .map_err(|err| AppError::RequestFailed(err.to_string()))
}

fn summary_cmp(a: &Summary, b: &Summary) -> Ordering {
    b.completed
        .cmp(&a.completed)
        .then_with(|| b.missed.cmp(&a.missed))
        .then_with(|| compare_user_id(a, b))
}

fn compare_user_id(a: &Summary, b: &Summary) -> Ordering {
    match (&a.user_id, &b.user_id) {
        (Value::Number(left), Value::Number(right)) if left.as_i64().is_some() && right.as_i64().is_some() => {
            left.as_i64().unwrap().cmp(&right.as_i64().unwrap())
        }
        (Value::Number(left), Value::Number(right)) => to_float(left)
            .partial_cmp(&to_float(right))
            .unwrap_or(Ordering::Equal),
        (Value::String(left), Value::String(right)) => left.cmp(right),
        (Value::Bool(left), Value::Bool(right)) => left.cmp(right),
        _ => a.key.cmp(&b.key),
    }
}

fn to_float(value: &Number) -> f64 {
    value
        .as_f64()
        .or_else(|| value.as_i64().map(|n| n as f64))
        .or_else(|| value.as_u64().map(|n| n as f64))
        .unwrap_or(0.0)
}
