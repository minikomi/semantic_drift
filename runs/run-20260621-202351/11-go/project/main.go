package main

import (
	"bytes"
	"fmt"
	"math"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"unicode/utf8"
)

type kind int

const (
	undefinedKind kind = iota
	nullKind
	boolKind
	numberKind
	stringKind
	arrayKind
	objectKind
)

type member struct {
	key string
	val jv
}

type jv struct {
	kind kind
	b    bool
	n    float64
	s    string
	a    []jv
	o    []member
}

type summary struct {
	userID    jv
	completed int64
	missed    int64
}

type ctx struct {
	err string
}

func (c *ctx) fail(msg string) error {
	c.err = msg
	return fmt.Errorf("%s", msg)
}

type parser struct {
	ctx  *ctx
	text []byte
	pos  int
}

func (p *parser) skipWS() {
	for p.pos < len(p.text) {
		switch p.text[p.pos] {
		case ' ', '\n', '\r', '\t':
			p.pos++
		default:
			return
		}
	}
}

func (p *parser) peek() (byte, error) {
	if p.pos >= len(p.text) {
		return 0, p.ctx.fail("unexpected end of input")
	}
	return p.text[p.pos], nil
}

func (p *parser) consume(c byte) bool {
	if p.pos < len(p.text) && p.text[p.pos] == c {
		p.pos++
		return true
	}
	return false
}

func (p *parser) expect(c byte) error {
	if p.consume(c) {
		return nil
	}
	return p.ctx.fail(fmt.Sprintf("expected '%c'", c))
}

func (p *parser) literal(word []byte) error {
	if p.pos+len(word) <= len(p.text) && bytes.Equal(p.text[p.pos:p.pos+len(word)], word) {
		p.pos += len(word)
		return nil
	}
	return p.ctx.fail("unexpected token")
}

func hexValue(c byte) (uint32, bool) {
	switch {
	case c >= '0' && c <= '9':
		return uint32(c - '0'), true
	case c >= 'a' && c <= 'f':
		return uint32(10 + c - 'a'), true
	case c >= 'A' && c <= 'F':
		return uint32(10 + c - 'A'), true
	default:
		return 0, false
	}
}

func (p *parser) parseHex4() (uint32, error) {
	if p.pos+4 > len(p.text) {
		return 0, p.ctx.fail("invalid unicode escape")
	}
	var acc uint32
	for i := 0; i < 4; i++ {
		hv, ok := hexValue(p.text[p.pos])
		if !ok {
			p.ctx.err = "invalid unicode escape"
			return 0, fmt.Errorf("invalid unicode escape")
		}
		acc = (acc << 4) + hv
		p.pos++
	}
	return acc, nil
}

func appendCodepoint(out *strings.Builder, cp uint32) error {
	r := rune(cp)
	if r == utf8.RuneError && cp != uint32(utf8.RuneError) {
		return fmt.Errorf("invalid codepoint")
	}
	out.WriteRune(r)
	return nil
}

func (p *parser) parseString() (string, error) {
	if err := p.expect('"'); err != nil {
		return "", err
	}
	var out strings.Builder
	for {
		if p.pos >= len(p.text) {
			return "", p.ctx.fail("unterminated string")
		}
		c := p.text[p.pos]
		p.pos++
		if c == '"' {
			break
		}
		if c < 0x20 {
			return "", p.ctx.fail("control character in string")
		}
		if c == '\\' {
			if p.pos >= len(p.text) {
				return "", p.ctx.fail("invalid escape")
			}
			esc := p.text[p.pos]
			p.pos++
			switch esc {
			case '"':
				out.WriteByte('"')
			case '\\':
				out.WriteByte('\\')
			case '/':
				out.WriteByte('/')
			case 'b':
				out.WriteRune('\u0008')
			case 'f':
				out.WriteRune('\u000c')
			case 'n':
				out.WriteByte('\n')
			case 'r':
				out.WriteByte('\r')
			case 't':
				out.WriteByte('\t')
			case 'u':
				cp, err := p.parseHex4()
				if err != nil {
					return "", err
				}
				if cp >= 0xD800 && cp <= 0xDBFF {
					if p.pos+6 > len(p.text) || p.text[p.pos] != '\\' || p.text[p.pos+1] != 'u' {
						return "", p.ctx.fail("invalid unicode surrogate")
					}
					p.pos += 2
					low, err := p.parseHex4()
					if err != nil {
						return "", err
					}
					if low < 0xDC00 || low > 0xDFFF {
						return "", p.ctx.fail("invalid unicode surrogate")
					}
					cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00)
				}
				if err := appendCodepoint(&out, cp); err != nil {
					return "", err
				}
			default:
				return "", p.ctx.fail("invalid escape")
			}
		} else {
			out.WriteByte(c)
		}
	}
	return out.String(), nil
}

func isDigit(c byte) bool { return c >= '0' && c <= '9' }

func (p *parser) consumeDigits() {
	for p.pos < len(p.text) && isDigit(p.text[p.pos]) {
		p.pos++
	}
}

func (p *parser) parseNumber() (jv, error) {
	begin := p.pos
	if p.pos < len(p.text) && (p.text[p.pos] == '+' || p.text[p.pos] == '-') {
		p.pos++
	}
	p.consumeDigits()
	if p.pos < len(p.text) && p.text[p.pos] == '.' {
		p.pos++
		p.consumeDigits()
	}
	if p.pos < len(p.text) && (p.text[p.pos] == 'e' || p.text[p.pos] == 'E') {
		save := p.pos
		p.pos++
		if p.pos < len(p.text) && (p.text[p.pos] == '+' || p.text[p.pos] == '-') {
			p.pos++
		}
		expBegin := p.pos
		p.consumeDigits()
		if expBegin == p.pos {
			p.pos = save
		}
	}
	end := p.pos
	if begin == end || (end == begin+1 && (p.text[begin] == '+' || p.text[begin] == '-')) {
		return jv{}, p.ctx.fail("unexpected token")
	}
	n, err := strconv.ParseFloat(string(p.text[begin:end]), 64)
	if err != nil {
		p.ctx.err = "unexpected token"
		return jv{}, err
	}
	return jv{kind: numberKind, n: n}, nil
}

func addOrReplace(obj *[]member, key string, val jv) {
	for i := range *obj {
		if (*obj)[i].key == key {
			(*obj)[i].val = val
			return
		}
	}
	*obj = append(*obj, member{key: key, val: val})
}

func (p *parser) parseArray() (jv, error) {
	if err := p.expect('['); err != nil {
		return jv{}, err
	}
	p.skipWS()
	var arr []jv
	if p.consume(']') {
		return jv{kind: arrayKind, a: arr}, nil
	}
	for {
		val, err := p.parseValue()
		if err != nil {
			return jv{}, err
		}
		arr = append(arr, val)
		p.skipWS()
		if p.consume(']') {
			return jv{kind: arrayKind, a: arr}, nil
		}
		if err := p.expect(','); err != nil {
			return jv{}, err
		}
	}
}

func (p *parser) parseObject() (jv, error) {
	if err := p.expect('{'); err != nil {
		return jv{}, err
	}
	p.skipWS()
	var obj []member
	if p.consume('}') {
		return jv{kind: objectKind, o: obj}, nil
	}
	for {
		p.skipWS()
		key, err := p.parseString()
		if err != nil {
			return jv{}, err
		}
		p.skipWS()
		if err := p.expect(':'); err != nil {
			return jv{}, err
		}
		val, err := p.parseValue()
		if err != nil {
			return jv{}, err
		}
		addOrReplace(&obj, key, val)
		p.skipWS()
		if p.consume('}') {
			return jv{kind: objectKind, o: obj}, nil
		}
		if err := p.expect(','); err != nil {
			return jv{}, err
		}
	}
}

func (p *parser) parseValue() (jv, error) {
	p.skipWS()
	c, err := p.peek()
	if err != nil {
		return jv{}, err
	}
	switch c {
	case 'n':
		if err := p.literal([]byte("null")); err != nil {
			return jv{}, err
		}
		return jv{kind: nullKind}, nil
	case 't':
		if err := p.literal([]byte("true")); err != nil {
			return jv{}, err
		}
		return jv{kind: boolKind, b: true}, nil
	case 'f':
		if err := p.literal([]byte("false")); err != nil {
			return jv{}, err
		}
		return jv{kind: boolKind}, nil
	case '"':
		s, err := p.parseString()
		return jv{kind: stringKind, s: s}, err
	case '[':
		return p.parseArray()
	case '{':
		return p.parseObject()
	default:
		return p.parseNumber()
	}
}

func parseJSON(c *ctx, s []byte) (jv, error) {
	p := parser{ctx: c, text: s}
	v, err := p.parseValue()
	if err != nil {
		return jv{}, err
	}
	p.skipWS()
	if p.pos != len(s) {
		return jv{}, p.ctx.fail(fmt.Sprintf("unexpected token at '%c'", p.text[p.pos]))
	}
	return v, nil
}

func appendJSONString(out *strings.Builder, s string) {
	out.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			out.WriteString("\\\"")
		case '\\':
			out.WriteString("\\\\")
		case 8:
			out.WriteString("\\b")
		case 12:
			out.WriteString("\\f")
		case '\n':
			out.WriteString("\\n")
		case '\r':
			out.WriteString("\\r")
		case '\t':
			out.WriteString("\\t")
		default:
			if c <= 7 || c == 11 || (c >= 14 && c <= 31) {
				out.WriteString(fmt.Sprintf("\\u%04x", c))
			} else {
				out.WriteByte(c)
			}
		}
	}
	out.WriteByte('"')
}

func isInteger(n float64) bool {
	return !math.IsNaN(n) && !math.IsInf(n, 0) && math.Floor(n) == n && n >= -9223372036854775808.0 && n <= 9223372036854775808.0
}

func appendNumber(out *strings.Builder, n float64) {
	if isInteger(n) && n >= 9223372036854775808.0 {
		out.WriteString("9223372036854775807")
	} else if isInteger(n) && n <= -9223372036854775808.0 {
		out.WriteString("-9223372036854775808")
	} else if isInteger(n) {
		out.WriteString(strconv.FormatInt(int64(n), 10))
	} else {
		s := fmt.Sprintf("%.15f", n)
		for strings.HasSuffix(s, "0") {
			s = s[:len(s)-1]
		}
		if strings.HasSuffix(s, ".") {
			s = s[:len(s)-1]
		}
		out.WriteString(s)
	}
}

func appendPyRepr(out *strings.Builder, v jv) {
	switch v.kind {
	case undefinedKind:
		out.WriteString("undefined")
	case nullKind:
		out.WriteString("None")
	case boolKind:
		if v.b {
			out.WriteString("True")
		} else {
			out.WriteString("False")
		}
	case numberKind:
		appendNumber(out, v.n)
	case stringKind:
		appendJSONString(out, v.s)
	case arrayKind:
		out.WriteByte('[')
		for i, item := range v.a {
			if i != 0 {
				out.WriteString(", ")
			}
			appendPyRepr(out, item)
		}
		out.WriteByte(']')
	case objectKind:
		out.WriteByte('{')
		for i, m := range v.o {
			if i != 0 {
				out.WriteString(", ")
			}
			appendJSONString(out, m.key)
			out.WriteString(": ")
			appendPyRepr(out, m.val)
		}
		out.WriteByte('}')
	}
}

func pyRepr(v jv) string {
	var out strings.Builder
	appendPyRepr(&out, v)
	return out.String()
}

func appendJSONStringify(out *strings.Builder, v jv) {
	switch v.kind {
	case undefinedKind:
		out.WriteString("undefined")
	case nullKind:
		out.WriteString("null")
	case boolKind:
		if v.b {
			out.WriteString("true")
		} else {
			out.WriteString("false")
		}
	case numberKind:
		appendNumber(out, v.n)
	case stringKind:
		appendJSONString(out, v.s)
	case arrayKind:
		out.WriteByte('[')
		for i, item := range v.a {
			if i != 0 {
				out.WriteByte(',')
			}
			appendJSONStringify(out, item)
		}
		out.WriteByte(']')
	case objectKind:
		out.WriteByte('{')
		for i, m := range v.o {
			if i != 0 {
				out.WriteByte(',')
			}
			appendJSONString(out, m.key)
			out.WriteByte(':')
			appendJSONStringify(out, m.val)
		}
		out.WriteByte('}')
	}
}

func jsonStringify(v jv) string {
	var out strings.Builder
	appendJSONStringify(&out, v)
	return out.String()
}

func jsString(v jv) string {
	switch v.kind {
	case undefinedKind:
		return "undefined"
	case nullKind:
		return "null"
	case boolKind:
		if v.b {
			return "true"
		}
		return "false"
	case stringKind:
		return v.s
	case numberKind:
		var out strings.Builder
		appendNumber(&out, v.n)
		return out.String()
	case arrayKind, objectKind:
		return pyRepr(v)
	default:
		return ""
	}
}

func pyStr(v jv) string {
	switch v.kind {
	case nullKind:
		return "None"
	case boolKind:
		if v.b {
			return "True"
		}
		return "False"
	case arrayKind, objectKind:
		return pyRepr(v)
	default:
		return jsString(v)
	}
}

func truthy(v jv) bool {
	switch v.kind {
	case undefinedKind:
		return true
	case nullKind:
		return false
	case boolKind:
		return v.b
	case numberKind:
		return v.n != 0.0
	case stringKind:
		return v.s != ""
	case arrayKind:
		return len(v.a) != 0
	case objectKind:
		return len(v.o) != 0
	default:
		return false
	}
}

var undefined = jv{kind: undefinedKind}

func objectGet(v jv, key string) jv {
	if v.kind == objectKind {
		for _, m := range v.o {
			if m.key == key {
				return m.val
			}
		}
	}
	return undefined
}

func leapYear(year int64) bool {
	return mod(year, 4) == 0 && (mod(year, 100) != 0 || mod(year, 400) == 0)
}

func daysInMonth(year, month int64) int64 {
	switch month {
	case 1, 3, 5, 7, 8, 10, 12:
		return 31
	case 4, 6, 9, 11:
		return 30
	case 2:
		if leapYear(year) {
			return 29
		}
		return 28
	default:
		return 0
	}
}

func mod(a, b int64) int64 {
	r := a % b
	if r < 0 {
		r += b
	}
	return r
}

func divFloor(a, b int64) int64 {
	q := a / b
	r := a % b
	if r != 0 && ((r < 0) != (b < 0)) {
		q--
	}
	return q
}

func daysFromCivil(y, m, d int64) int64 {
	if m <= 2 {
		y--
	}
	era := divFloor(y, 400)
	yoe := y - era*400
	mp := m
	if m > 2 {
		mp -= 3
	} else {
		mp += 9
	}
	doy := divFloor(153*mp+2, 5) + d - 1
	doe := yoe*365 + divFloor(yoe, 4) - divFloor(yoe, 100) + doy
	return era*146097 + doe - 719468
}

func parseDateParts(c *ctx, txt, stringify string) (int64, error) {
	b := []byte(txt)
	shape := len(b) == 10 && isDigit(b[0]) && isDigit(b[1]) && isDigit(b[2]) && isDigit(b[3]) &&
		b[4] == '-' && isDigit(b[5]) && isDigit(b[6]) && b[7] == '-' && isDigit(b[8]) && isDigit(b[9])
	if !shape {
		return 0, c.fail(fmt.Sprintf("parsing time %s as \"2006-01-02\": cannot parse date", stringify))
	}
	year, _ := strconv.ParseInt(txt[0:4], 10, 64)
	month, _ := strconv.ParseInt(txt[5:7], 10, 64)
	day, _ := strconv.ParseInt(txt[8:10], 10, 64)
	if (year >= 0 && year <= 99) || month < 1 || month > 12 || day < 1 || day > daysInMonth(year, month) {
		return 0, c.fail(fmt.Sprintf("parsing time %s: day out of range", stringify))
	}
	return daysFromCivil(year, month, day), nil
}

func parseDateOnly(c *ctx, v jv) (int64, error) {
	return parseDateParts(c, jsString(v), jsonStringify(v))
}

func canonicalKey(v jv) string {
	return jsonStringify(v)
}

func adjustSummary(summaries *[]summary, userID jv, completedDelta, missedDelta int64) {
	key := canonicalKey(userID)
	for i := range *summaries {
		if key == canonicalKey((*summaries)[i].userID) {
			(*summaries)[i].completed += completedDelta
			(*summaries)[i].missed += missedDelta
			return
		}
	}
	*summaries = append(*summaries, summary{userID: userID, completed: completedDelta, missed: missedDelta})
}

func nextCodepoint(bytes []byte, idx *int) uint32 {
	if r, size := utf8.DecodeRune(bytes[*idx:]); r != utf8.RuneError || size != 1 {
		*idx += size
		return uint32(r)
	}
	c := uint32(bytes[*idx])
	*idx++
	return c
}

func utf16Units(cp uint32) []uint32 {
	if cp <= 0xFFFF {
		return []uint32{cp}
	}
	x := cp - 0x10000
	return []uint32{0xD800 + x/0x400, 0xDC00 + x%0x400}
}

func compareJavaString(a, b string) int {
	ab, bb := []byte(a), []byte(b)
	ia, ib := 0, 0
	for ia < len(ab) && ib < len(bb) {
		cpa := nextCodepoint(ab, &ia)
		cpb := nextCodepoint(bb, &ib)
		if cpa <= 0xFFFF && cpb <= 0xFFFF {
			if cpa < cpb {
				return -1
			}
			if cpa > cpb {
				return 1
			}
		} else {
			ua := utf16Units(cpa)
			ub := utf16Units(cpb)
			j := 0
			for j < len(ua) && j < len(ub) {
				if ua[j] < ub[j] {
					return -1
				}
				if ua[j] > ub[j] {
					return 1
				}
				j++
			}
			if len(ua) < len(ub) {
				return -1
			}
			if len(ua) > len(ub) {
				return 1
			}
		}
	}
	if ia == len(ab) && ib == len(bb) {
		return 0
	}
	if ia == len(ab) {
		return -1
	}
	return 1
}

type pyKey struct {
	group int
	num   float64
	text  string
}

func makePyKey(v jv) pyKey {
	switch v.kind {
	case nullKind:
		return pyKey{group: 0}
	case boolKind:
		if v.b {
			return pyKey{group: 1, num: 1}
		}
		return pyKey{group: 1}
	case numberKind:
		return pyKey{group: 1, num: v.n}
	case stringKind:
		return pyKey{group: 2, text: v.s}
	default:
		return pyKey{group: 3, text: jsString(v)}
	}
}

func summaryLess(a, b summary) bool {
	if a.completed != b.completed {
		return a.completed > b.completed
	}
	if a.missed != b.missed {
		return a.missed > b.missed
	}
	ka, kb := makePyKey(a.userID), makePyKey(b.userID)
	if ka.group != kb.group {
		return ka.group < kb.group
	}
	if ka.group == 1 && ka.num != kb.num {
		return ka.num < kb.num
	}
	return compareJavaString(ka.text, kb.text) < 0
}

func javaLength(s string) int {
	n := 0
	for _, r := range s {
		if uint32(r) > 0xFFFF {
			n += 2
		} else {
			n++
		}
	}
	return n
}

func appendLjust(out *strings.Builder, s string, width int) {
	out.WriteString(s)
	if l := javaLength(s); l < width {
		for i := l; i < width; i++ {
			out.WriteByte(' ')
		}
	}
}

func splitHTTPResponse(c *ctx, s []byte) (status *int64, reason string, body []byte, err error) {
	crlfPos := bytes.Index(s, []byte("\r\n\r\n"))
	lfPos := bytes.Index(s, []byte("\n\n"))
	sep := -1
	if crlfPos >= 0 {
		sep = crlfPos
	} else if lfPos >= 0 {
		sep = lfPos
	}
	sepLen := 2
	if sep >= 0 && sep+4 <= len(s) && bytes.Equal(s[sep:sep+4], []byte("\r\n\r\n")) {
		sepLen = 4
	}
	header := s
	if sep >= 0 {
		header = s[:sep]
		body = append([]byte(nil), s[sep+sepLen:]...)
	} else {
		body = []byte{}
	}
	lineEnd := len(header)
	if p := bytes.IndexByte(header, '\r'); p >= 0 {
		lineEnd = p
	}
	if p := bytes.IndexByte(header, '\n'); p >= 0 && p < lineEnd {
		lineEnd = p
	}
	statusLine := string(header[:lineEnd])
	words := strings.FieldsFunc(statusLine, func(r rune) bool { return r == ' ' || r == '\t' })
	if len(words) >= 2 {
		proto, codeTxt := words[0], words[1]
		if (proto == "HTTP/1.0" || proto == "HTTP/1.1" || proto == "HTTP/2" || proto == "HTTP/3") && codeTxt != "" {
			allDigits := true
			for i := 0; i < len(codeTxt); i++ {
				if !isDigit(codeTxt[i]) {
					allDigits = false
					break
				}
			}
			if allDigits {
				if n, e := strconv.ParseInt(codeTxt, 10, 64); e == nil {
					status = &n
				}
			}
		}
		if len(words) > 2 {
			reason = strings.Join(words[2:], " ")
		}
	}
	_ = c
	return status, reason, body, nil
}

func trimTrailingNewline(s []byte) string {
	end := len(s)
	for end > 0 && s[end-1] == '\n' {
		end--
	}
	return string(s[:end])
}

func fetchJSON(c *ctx, url string) (jv, error) {
	res := exec.Command("curl", "--silent", "--show-error", "--include", "--max-time", "10", "--connect-timeout", "10", url)
	out, err := res.Output()
	if err == nil {
		status, reason, body, _ := splitHTTPResponse(c, out)
		if status != nil {
			if *status >= 200 && *status < 300 {
				return parseJSON(c, body)
			}
			if reason == "" {
				return jv{}, c.fail(fmt.Sprintf("bad status: %d", *status))
			}
			return jv{}, c.fail(fmt.Sprintf("bad status: %d %s", *status, reason))
		}
		return jv{}, c.fail("bad status: 000")
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return jv{}, c.fail(trimTrailingNewline(ee.Stderr))
	}
	c.err = err.Error()
	return jv{}, err
}

func today(c *ctx) (int64, error) {
	res := exec.Command("date", "+%Y-%m-%d")
	out, err := res.Output()
	if err == nil {
		txt := trimTrailingNewline(out)
		return parseDateParts(c, txt, txt)
	}
	if ee, ok := err.(*exec.ExitError); ok {
		return 0, c.fail(trimTrailingNewline(ee.Stderr))
	}
	c.err = err.Error()
	return 0, err
}

func processTodos(c *ctx, todayDay int64, todos jv) (string, error) {
	var summaries []summary
	if todos.kind == arrayKind {
		for _, todo := range todos.a {
			userID := objectGet(todo, "userId")
			completed := objectGet(todo, "completed")
			if truthy(completed) {
				adjustSummary(&summaries, userID, 1, 0)
			} else {
				due, err := parseDateOnly(c, objectGet(todo, "dueDate"))
				if err != nil {
					return "", err
				}
				if due < todayDay {
					adjustSummary(&summaries, userID, 0, 1)
				} else {
					adjustSummary(&summaries, userID, 0, 0)
				}
			}
		}
	}
	for i := 1; i < len(summaries); i++ {
		for j := i; j > 0 && summaryLess(summaries[j], summaries[j-1]); j-- {
			summaries[j], summaries[j-1] = summaries[j-1], summaries[j]
		}
	}
	var out strings.Builder
	out.WriteString("USER  COMPLETED  MISSED\n")
	for _, s := range summaries {
		u := pyStr(s.userID)
		appendLjust(&out, u, 5)
		out.WriteByte(' ')
		appendLjust(&out, strconv.FormatInt(s.completed, 10), 10)
		out.WriteString(fmt.Sprintf(" %d\n", s.missed))
	}
	return out.String(), nil
}

func main() {
	args := os.Args
	c := &ctx{}
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: TodoReport <todos-url>")
		os.Exit(1)
	}
	t, err := today(c)
	if err != nil {
		if c.err == "" {
			c.err = "unknown error"
		}
		fmt.Fprintln(os.Stderr, c.err)
		os.Exit(1)
	}
	todos, err := fetchJSON(c, args[1])
	if err != nil {
		if c.err == "" {
			c.err = "unknown error"
		}
		fmt.Fprintln(os.Stderr, c.err)
		os.Exit(1)
	}
	output, err := processTodos(c, t, todos)
	if err != nil {
		if c.err == "" {
			c.err = "unknown error"
		}
		fmt.Fprintln(os.Stderr, c.err)
		os.Exit(1)
	}
	fmt.Print(output)
}
