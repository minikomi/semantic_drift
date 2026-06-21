use std::env;
use std::process::{Command, ExitCode};

#[derive(Clone)]
enum Jv {
    Undefined,
    Null,
    Bool(bool),
    Number(f64),
    String(String),
    Array(Vec<Jv>),
    Object(Vec<(String, Jv)>),
}

struct Summary {
    user_id: Jv,
    completed: i64,
    missed: i64,
}

struct Ctx {
    err: Option<String>,
}

impl Ctx {
    fn new() -> Self {
        Self { err: None }
    }

    fn fail<T>(&mut self, msg: impl Into<String>) -> Result<T, ()> {
        self.err = Some(msg.into());
        Err(())
    }
}

struct Parser<'a, 'c> {
    ctx: &'c mut Ctx,
    text: &'a [u8],
    pos: usize,
}

impl<'a, 'c> Parser<'a, 'c> {
    fn skip_ws(&mut self) {
        while self.pos < self.text.len() {
            match self.text[self.pos] {
                b' ' | b'\n' | b'\r' | b'\t' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&mut self) -> Result<u8, ()> {
        if self.pos >= self.text.len() {
            self.ctx.fail("unexpected end of input")
        } else {
            Ok(self.text[self.pos])
        }
    }

    fn consume(&mut self, c: u8) -> bool {
        if self.pos < self.text.len() && self.text[self.pos] == c {
            self.pos += 1;
            true
        } else {
            false
        }
    }

    fn expect(&mut self, c: u8) -> Result<(), ()> {
        if self.consume(c) {
            Ok(())
        } else {
            self.ctx.fail(format!("expected '{}'", c as char))
        }
    }

    fn literal(&mut self, word: &[u8]) -> Result<(), ()> {
        if self.pos + word.len() <= self.text.len()
            && &self.text[self.pos..self.pos + word.len()] == word
        {
            self.pos += word.len();
            Ok(())
        } else {
            self.ctx.fail("unexpected token")
        }
    }

    fn hex_value(c: u8) -> Option<u32> {
        match c {
            b'0'..=b'9' => Some((c - b'0') as u32),
            b'a'..=b'f' => Some((10 + c - b'a') as u32),
            b'A'..=b'F' => Some((10 + c - b'A') as u32),
            _ => None,
        }
    }

    fn parse_hex4(&mut self) -> Result<u32, ()> {
        if self.pos + 4 > self.text.len() {
            return self.ctx.fail("invalid unicode escape");
        }
        let mut acc = 0u32;
        for _ in 0..4 {
            let hv = Self::hex_value(self.text[self.pos])
                .ok_or_else(|| {
                    self.ctx.err = Some("invalid unicode escape".to_string());
                })?;
            acc = (acc << 4) + hv;
            self.pos += 1;
        }
        Ok(acc)
    }

    fn append_codepoint(out: &mut String, cp: u32) -> Result<(), ()> {
        if let Some(ch) = char::from_u32(cp) {
            out.push(ch);
            Ok(())
        } else {
            Err(())
        }
    }

    fn parse_string(&mut self) -> Result<String, ()> {
        self.expect(b'"')?;
        let mut out = String::new();
        loop {
            if self.pos >= self.text.len() {
                return self.ctx.fail("unterminated string");
            }
            let c = self.text[self.pos];
            self.pos += 1;
            if c == b'"' {
                break;
            }
            if c < 0x20 {
                return self.ctx.fail("control character in string");
            }
            if c == b'\\' {
                if self.pos >= self.text.len() {
                    return self.ctx.fail("invalid escape");
                }
                let esc = self.text[self.pos];
                self.pos += 1;
                match esc {
                    b'"' => out.push('"'),
                    b'\\' => out.push('\\'),
                    b'/' => out.push('/'),
                    b'b' => out.push('\u{0008}'),
                    b'f' => out.push('\u{000c}'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'u' => {
                        let mut cp = self.parse_hex4()?;
                        if (0xD800..=0xDBFF).contains(&cp) {
                            if self.pos + 6 > self.text.len()
                                || self.text[self.pos] != b'\\'
                                || self.text[self.pos + 1] != b'u'
                            {
                                return self.ctx.fail("invalid unicode surrogate");
                            }
                            self.pos += 2;
                            let low = self.parse_hex4()?;
                            if !(0xDC00..=0xDFFF).contains(&low) {
                                return self.ctx.fail("invalid unicode surrogate");
                            }
                            cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                        }
                        Self::append_codepoint(&mut out, cp)?;
                    }
                    _ => return self.ctx.fail("invalid escape"),
                }
            } else {
                out.push(c as char);
            }
        }
        Ok(out)
    }

    fn is_digit(c: u8) -> bool {
        c.is_ascii_digit()
    }

    fn consume_digits(&mut self) {
        while self.pos < self.text.len() && Self::is_digit(self.text[self.pos]) {
            self.pos += 1;
        }
    }

    fn parse_number(&mut self) -> Result<Jv, ()> {
        let begin = self.pos;
        if self.pos < self.text.len() && (self.text[self.pos] == b'+' || self.text[self.pos] == b'-') {
            self.pos += 1;
        }
        self.consume_digits();
        if self.pos < self.text.len() && self.text[self.pos] == b'.' {
            self.pos += 1;
            self.consume_digits();
        }
        if self.pos < self.text.len() && (self.text[self.pos] == b'e' || self.text[self.pos] == b'E') {
            let save = self.pos;
            self.pos += 1;
            if self.pos < self.text.len() && (self.text[self.pos] == b'+' || self.text[self.pos] == b'-') {
                self.pos += 1;
            }
            let exp_begin = self.pos;
            self.consume_digits();
            if exp_begin == self.pos {
                self.pos = save;
            }
        }
        let end = self.pos;
        if begin == end || (end == begin + 1 && (self.text[begin] == b'+' || self.text[begin] == b'-')) {
            return self.ctx.fail("unexpected token");
        }
        let s = std::str::from_utf8(&self.text[begin..end]).map_err(|_| {
            self.ctx.err = Some("unexpected token".to_string());
        })?;
        let n = s.parse::<f64>().map_err(|_| {
            self.ctx.err = Some("unexpected token".to_string());
        })?;
        Ok(Jv::Number(n))
    }

    fn add_or_replace(obj: &mut Vec<(String, Jv)>, key: String, value: Jv) {
        for (k, v) in obj.iter_mut() {
            if *k == key {
                *v = value;
                return;
            }
        }
        obj.push((key, value));
    }

    fn parse_array(&mut self) -> Result<Jv, ()> {
        self.expect(b'[')?;
        self.skip_ws();
        let mut arr = Vec::new();
        if self.consume(b']') {
            return Ok(Jv::Array(arr));
        }
        loop {
            let val = self.parse_value()?;
            arr.push(val);
            self.skip_ws();
            if self.consume(b']') {
                return Ok(Jv::Array(arr));
            }
            self.expect(b',')?;
        }
    }

    fn parse_object(&mut self) -> Result<Jv, ()> {
        self.expect(b'{')?;
        self.skip_ws();
        let mut obj = Vec::new();
        if self.consume(b'}') {
            return Ok(Jv::Object(obj));
        }
        loop {
            self.skip_ws();
            let key = self.parse_string()?;
            self.skip_ws();
            self.expect(b':')?;
            let val = self.parse_value()?;
            Self::add_or_replace(&mut obj, key, val);
            self.skip_ws();
            if self.consume(b'}') {
                return Ok(Jv::Object(obj));
            }
            self.expect(b',')?;
        }
    }

    fn parse_value(&mut self) -> Result<Jv, ()> {
        self.skip_ws();
        match self.peek()? {
            b'n' => {
                self.literal(b"null")?;
                Ok(Jv::Null)
            }
            b't' => {
                self.literal(b"true")?;
                Ok(Jv::Bool(true))
            }
            b'f' => {
                self.literal(b"false")?;
                Ok(Jv::Bool(false))
            }
            b'"' => Ok(Jv::String(self.parse_string()?)),
            b'[' => self.parse_array(),
            b'{' => self.parse_object(),
            _ => self.parse_number(),
        }
    }
}

fn parse_json(ctx: &mut Ctx, s: &[u8]) -> Result<Jv, ()> {
    let mut p = Parser { ctx, text: s, pos: 0 };
    let v = p.parse_value()?;
    p.skip_ws();
    if p.pos != s.len() {
        return p.ctx.fail(format!("unexpected token at '{}'", p.text[p.pos] as char));
    }
    Ok(v)
}

fn append_json_string(out: &mut String, s: &str) {
    out.push('"');
    for c in s.bytes() {
        match c {
            b'"' => out.push_str("\\\""),
            b'\\' => out.push_str("\\\\"),
            8 => out.push_str("\\b"),
            12 => out.push_str("\\f"),
            b'\n' => out.push_str("\\n"),
            b'\r' => out.push_str("\\r"),
            b'\t' => out.push_str("\\t"),
            0..=7 | 11 | 14..=31 => out.push_str(&format!("\\u{:0>4x}", c)),
            _ => out.push(c as char),
        }
    }
    out.push('"');
}

fn is_integer(n: f64) -> bool {
    !n.is_nan() && !n.is_infinite() && n.floor() == n && n >= -9223372036854775808.0 && n <= 9223372036854775808.0
}

fn append_number(out: &mut String, n: f64) {
    if is_integer(n) && n >= 9223372036854775808.0 {
        out.push_str("9223372036854775807");
    } else if is_integer(n) && n <= -9223372036854775808.0 {
        out.push_str("-9223372036854775808");
    } else if is_integer(n) {
        out.push_str(&(n as i64).to_string());
    } else {
        let mut s = format!("{:.15}", n);
        while s.ends_with('0') {
            s.pop();
        }
        if s.ends_with('.') {
            s.pop();
        }
        out.push_str(&s);
    }
}

fn append_py_repr(out: &mut String, v: &Jv) {
    match v {
        Jv::Undefined => out.push_str("undefined"),
        Jv::Null => out.push_str("None"),
        Jv::Bool(b) => out.push_str(if *b { "True" } else { "False" }),
        Jv::Number(n) => append_number(out, *n),
        Jv::String(s) => append_json_string(out, s),
        Jv::Array(arr) => {
            out.push('[');
            for (i, item) in arr.iter().enumerate() {
                if i != 0 {
                    out.push_str(", ");
                }
                append_py_repr(out, item);
            }
            out.push(']');
        }
        Jv::Object(obj) => {
            out.push('{');
            for (i, (k, v)) in obj.iter().enumerate() {
                if i != 0 {
                    out.push_str(", ");
                }
                append_json_string(out, k);
                out.push_str(": ");
                append_py_repr(out, v);
            }
            out.push('}');
        }
    }
}

fn py_repr(v: &Jv) -> String {
    let mut out = String::new();
    append_py_repr(&mut out, v);
    out
}

fn append_json_stringify(out: &mut String, v: &Jv) {
    match v {
        Jv::Undefined => out.push_str("undefined"),
        Jv::Null => out.push_str("null"),
        Jv::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Jv::Number(n) => append_number(out, *n),
        Jv::String(s) => append_json_string(out, s),
        Jv::Array(arr) => {
            out.push('[');
            for (i, item) in arr.iter().enumerate() {
                if i != 0 {
                    out.push(',');
                }
                append_json_stringify(out, item);
            }
            out.push(']');
        }
        Jv::Object(obj) => {
            out.push('{');
            for (i, (k, v)) in obj.iter().enumerate() {
                if i != 0 {
                    out.push(',');
                }
                append_json_string(out, k);
                out.push(':');
                append_json_stringify(out, v);
            }
            out.push('}');
        }
    }
}

fn json_stringify(v: &Jv) -> String {
    let mut out = String::new();
    append_json_stringify(&mut out, v);
    out
}

fn js_string(v: &Jv) -> String {
    match v {
        Jv::Undefined => "undefined".to_string(),
        Jv::Null => "null".to_string(),
        Jv::Bool(b) => if *b { "true" } else { "false" }.to_string(),
        Jv::String(s) => s.clone(),
        Jv::Number(n) => {
            let mut out = String::new();
            append_number(&mut out, *n);
            out
        }
        Jv::Array(_) | Jv::Object(_) => py_repr(v),
    }
}

fn py_str(v: &Jv) -> String {
    match v {
        Jv::Null => "None".to_string(),
        Jv::Bool(b) => if *b { "True" } else { "False" }.to_string(),
        Jv::Array(_) | Jv::Object(_) => py_repr(v),
        _ => js_string(v),
    }
}

fn truthy(v: &Jv) -> bool {
    match v {
        Jv::Undefined => true,
        Jv::Null => false,
        Jv::Bool(b) => *b,
        Jv::Number(n) => *n != 0.0,
        Jv::String(s) => !s.is_empty(),
        Jv::Array(a) => !a.is_empty(),
        Jv::Object(o) => !o.is_empty(),
    }
}

static UNDEFINED: Jv = Jv::Undefined;

fn object_get<'a>(v: &'a Jv, key: &str) -> &'a Jv {
    if let Jv::Object(obj) = v {
        for (k, val) in obj {
            if k == key {
                return val;
            }
        }
    }
    &UNDEFINED
}

fn leap_year(year: i64) -> bool {
    year.rem_euclid(4) == 0 && (year.rem_euclid(100) != 0 || year.rem_euclid(400) == 0)
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 => if leap_year(year) { 29 } else { 28 },
        _ => 0,
    }
}

fn div_floor(a: i64, b: i64) -> i64 {
    a.div_euclid(b)
}

fn days_from_civil(y_: i64, m_: i64, d_: i64) -> i64 {
    let mut y = y_;
    let m = m_;
    let d = d_;
    if m <= 2 {
        y -= 1;
    }
    let era = div_floor(y, 400);
    let yoe = y - era * 400;
    let mp = m + if m > 2 { -3 } else { 9 };
    let doy = div_floor(153 * mp + 2, 5) + d - 1;
    let doe = yoe * 365 + div_floor(yoe, 4) - div_floor(yoe, 100) + doy;
    era * 146097 + doe - 719468
}

fn parse_date_parts(ctx: &mut Ctx, txt: &str, stringify: &str) -> Result<i64, ()> {
    let b = txt.as_bytes();
    let shape = b.len() == 10
        && b[0].is_ascii_digit()
        && b[1].is_ascii_digit()
        && b[2].is_ascii_digit()
        && b[3].is_ascii_digit()
        && b[4] == b'-'
        && b[5].is_ascii_digit()
        && b[6].is_ascii_digit()
        && b[7] == b'-'
        && b[8].is_ascii_digit()
        && b[9].is_ascii_digit();
    if !shape {
        return ctx.fail(format!("parsing time {} as \"2006-01-02\": cannot parse date", stringify));
    }
    let year = txt[0..4].parse::<i64>().map_err(|_| ())?;
    let month = txt[5..7].parse::<i64>().map_err(|_| ())?;
    let day = txt[8..10].parse::<i64>().map_err(|_| ())?;
    if (0..=99).contains(&year) || month < 1 || month > 12 || day < 1 || day > days_in_month(year, month) {
        return ctx.fail(format!("parsing time {}: day out of range", stringify));
    }
    Ok(days_from_civil(year, month, day))
}

fn parse_date_only(ctx: &mut Ctx, v: &Jv) -> Result<i64, ()> {
    let txt = js_string(v);
    let strv = json_stringify(v);
    parse_date_parts(ctx, &txt, &strv)
}

fn canonical_key(v: &Jv) -> String {
    json_stringify(v)
}

fn adjust_summary(summaries: &mut Vec<Summary>, user_id: &Jv, completed_delta: i64, missed_delta: i64) {
    let key = canonical_key(user_id);
    for s in summaries.iter_mut() {
        let other = canonical_key(&s.user_id);
        if key == other {
            s.completed += completed_delta;
            s.missed += missed_delta;
            return;
        }
    }
    summaries.push(Summary {
        user_id: user_id.clone(),
        completed: completed_delta,
        missed: missed_delta,
    });
}

fn next_codepoint(bytes: &[u8], idx: &mut usize) -> u32 {
    let s = match std::str::from_utf8(&bytes[*idx..]) {
        Ok(s) => s,
        Err(_) => {
            let c = bytes[*idx] as u32;
            *idx += 1;
            return c;
        }
    };
    if let Some(ch) = s.chars().next() {
        *idx += ch.len_utf8();
        ch as u32
    } else {
        0
    }
}

fn compare_java_string(a: &str, b: &str) -> i32 {
    let ab = a.as_bytes();
    let bb = b.as_bytes();
    let mut ia = 0usize;
    let mut ib = 0usize;
    while ia < ab.len() && ib < bb.len() {
        let cpa = next_codepoint(ab, &mut ia);
        let cpb = next_codepoint(bb, &mut ib);
        if cpa <= 0xFFFF && cpb <= 0xFFFF {
            if cpa < cpb {
                return -1;
            }
            if cpa > cpb {
                return 1;
            }
        } else {
            let mut ua = [0u32; 2];
            let mut ub = [0u32; 2];
            let la = if cpa <= 0xFFFF {
                ua[0] = cpa;
                1
            } else {
                let x = cpa - 0x10000;
                ua[0] = 0xD800 + x / 0x400;
                ua[1] = 0xDC00 + x % 0x400;
                2
            };
            let lb = if cpb <= 0xFFFF {
                ub[0] = cpb;
                1
            } else {
                let x = cpb - 0x10000;
                ub[0] = 0xD800 + x / 0x400;
                ub[1] = 0xDC00 + x % 0x400;
                2
            };
            let mut j = 0usize;
            while j < la && j < lb {
                if ua[j] < ub[j] {
                    return -1;
                }
                if ua[j] > ub[j] {
                    return 1;
                }
                j += 1;
            }
            if la < lb {
                return -1;
            }
            if la > lb {
                return 1;
            }
        }
    }
    if ia == ab.len() && ib == bb.len() {
        0
    } else if ia == ab.len() {
        -1
    } else {
        1
    }
}

struct PyKey {
    group: i32,
    num: f64,
    text: String,
}

fn py_key(v: &Jv) -> PyKey {
    match v {
        Jv::Null => PyKey { group: 0, num: 0.0, text: String::new() },
        Jv::Bool(b) => PyKey { group: 1, num: if *b { 1.0 } else { 0.0 }, text: String::new() },
        Jv::Number(n) => PyKey { group: 1, num: *n, text: String::new() },
        Jv::String(s) => PyKey { group: 2, num: 0.0, text: s.clone() },
        _ => PyKey { group: 3, num: 0.0, text: js_string(v) },
    }
}

fn summary_less(a: &Summary, b: &Summary) -> bool {
    if a.completed != b.completed {
        return a.completed > b.completed;
    }
    if a.missed != b.missed {
        return a.missed > b.missed;
    }
    let ka = py_key(&a.user_id);
    let kb = py_key(&b.user_id);
    if ka.group != kb.group {
        return ka.group < kb.group;
    }
    if ka.group == 1 && ka.num != kb.num {
        return ka.num < kb.num;
    }
    compare_java_string(&ka.text, &kb.text) < 0
}

fn java_length(s: &str) -> usize {
    s.chars().map(|ch| if (ch as u32) > 0xFFFF { 2 } else { 1 }).sum()
}

fn append_ljust(out: &mut String, s: &str, width: usize) {
    out.push_str(s);
    let len = java_length(s);
    if len < width {
        for _ in len..width {
            out.push(' ');
        }
    }
}

fn split_http_response(ctx: &mut Ctx, s: &[u8]) -> Result<(Option<i64>, String, Vec<u8>), ()> {
    let crlf_pos = s.windows(4).position(|w| w == b"\r\n\r\n");
    let lf_pos = s.windows(2).position(|w| w == b"\n\n");
    let sep = crlf_pos.or(lf_pos);
    let sep_len = if let Some(p) = sep {
        if p + 4 <= s.len() && &s[p..p + 4] == b"\r\n\r\n" { 4 } else { 2 }
    } else {
        2
    };
    let header = if let Some(p) = sep { &s[..p] } else { s };
    let body = if let Some(p) = sep { s[p + sep_len..].to_vec() } else { Vec::new() };
    let mut line_end = header.len();
    if let Some(p) = header.iter().position(|&c| c == b'\r') {
        line_end = p;
    }
    if let Some(p) = header.iter().position(|&c| c == b'\n') {
        line_end = line_end.min(p);
    }
    let status_line = String::from_utf8_lossy(&header[..line_end]);
    let mut words = status_line.split(|c| c == ' ' || c == '\t').filter(|w| !w.is_empty());
    let proto = words.next();
    let code_txt = words.next();
    let mut status = None;
    if let (Some(proto), Some(code_txt)) = (proto, code_txt) {
        if matches!(proto, "HTTP/1.0" | "HTTP/1.1" | "HTTP/2" | "HTTP/3")
            && !code_txt.is_empty()
            && code_txt.bytes().all(|c| c.is_ascii_digit())
        {
            status = code_txt.parse::<i64>().ok();
        }
    }
    let reason = words.collect::<Vec<_>>().join(" ");
    let _ = ctx;
    Ok((status, reason, body))
}

fn trim_trailing_newline(s: &[u8]) -> String {
    let mut end = s.len();
    while end > 0 && s[end - 1] == b'\n' {
        end -= 1;
    }
    String::from_utf8_lossy(&s[..end]).to_string()
}

fn fetch_json(ctx: &mut Ctx, url: &str) -> Result<Jv, ()> {
    let res = Command::new("curl")
        .args(["--silent", "--show-error", "--include", "--max-time", "10", "--connect-timeout", "10", url])
        .output()
        .map_err(|e| {
            ctx.err = Some(e.to_string());
        })?;
    if res.status.code() == Some(0) {
        let (status, reason, body) = split_http_response(ctx, &res.stdout)?;
        if let Some(status) = status {
            if (200..300).contains(&status) {
                return parse_json(ctx, &body);
            }
            if reason.is_empty() {
                return ctx.fail(format!("bad status: {}", status));
            }
            return ctx.fail(format!("bad status: {} {}", status, reason));
        }
        return ctx.fail("bad status: 000");
    }
    ctx.fail(trim_trailing_newline(&res.stderr))
}

fn today(ctx: &mut Ctx) -> Result<i64, ()> {
    let res = Command::new("date")
        .arg("+%Y-%m-%d")
        .output()
        .map_err(|e| {
            ctx.err = Some(e.to_string());
        })?;
    if res.status.code() == Some(0) {
        let txt = trim_trailing_newline(&res.stdout);
        return parse_date_parts(ctx, &txt, &txt);
    }
    ctx.fail(trim_trailing_newline(&res.stderr))
}

fn process_todos(ctx: &mut Ctx, today_day: i64, todos: &Jv) -> Result<String, ()> {
    let mut summaries = Vec::new();
    if let Jv::Array(arr) = todos {
        for todo in arr {
            let user_id = object_get(todo, "userId");
            let completed = object_get(todo, "completed");
            if truthy(completed) {
                adjust_summary(&mut summaries, user_id, 1, 0);
            } else {
                let due = parse_date_only(ctx, object_get(todo, "dueDate"))?;
                if due < today_day {
                    adjust_summary(&mut summaries, user_id, 0, 1);
                } else {
                    adjust_summary(&mut summaries, user_id, 0, 0);
                }
            }
        }
    }

    let mut i = 1usize;
    while i < summaries.len() {
        let mut j = i;
        while j > 0 && summary_less(&summaries[j], &summaries[j - 1]) {
            summaries.swap(j, j - 1);
            j -= 1;
        }
        i += 1;
    }

    let mut out = String::new();
    out.push_str("USER  COMPLETED  MISSED\n");
    for s in &summaries {
        let u = py_str(&s.user_id);
        append_ljust(&mut out, &u, 5);
        out.push(' ');
        let c = s.completed.to_string();
        append_ljust(&mut out, &c, 10);
        out.push_str(&format!(" {}\n", s.missed));
    }
    Ok(out)
}

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    let mut ctx = Ctx::new();
    if args.len() != 2 {
        eprintln!("usage: TodoReport <todos-url>");
        return ExitCode::from(1);
    }
    let t = match today(&mut ctx) {
        Ok(t) => t,
        Err(()) => {
            eprintln!("{}", ctx.err.as_deref().unwrap_or("unknown error"));
            return ExitCode::from(1);
        }
    };
    let todos = match fetch_json(&mut ctx, &args[1]) {
        Ok(v) => v,
        Err(()) => {
            eprintln!("{}", ctx.err.as_deref().unwrap_or("unknown error"));
            return ExitCode::from(1);
        }
    };
    let output = match process_todos(&mut ctx, t, &todos) {
        Ok(o) => o,
        Err(()) => {
            eprintln!("{}", ctx.err.as_deref().unwrap_or("unknown error"));
            return ExitCode::from(1);
        }
    };
    print!("{}", output);
    ExitCode::SUCCESS
}
