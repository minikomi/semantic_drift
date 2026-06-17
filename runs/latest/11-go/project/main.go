package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strconv"
	"strings"
)

type kind int

const (
	kindNull kind = iota
	kindBool
	kindNumber
	kindString
	kindArray
	kindObject
)

type objectEntry struct {
	key   string
	value *value
}

type value struct {
	kind    kind
	boolVal bool
	raw     string
	array   []*value
	object  []objectEntry
}

type summary struct {
	userID    *value
	completed int64
	missed    int64
}

var nullValue = &value{kind: kindNull}

func fail(message string) error {
	fmt.Fprintln(os.Stderr, message)
	return fmt.Errorf("")
}

func parseJSON(text string) (*value, error) {
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	result, err := parseValue(decoder)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return nil, fmt.Errorf("")
	}
	if token, err := decoder.Token(); err != io.EOF {
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
		} else {
			fmt.Fprintf(os.Stderr, "invalid character %q after top-level value\n", token)
		}
		return nil, fmt.Errorf("")
	}
	return result, nil
}

func parseValue(decoder *json.Decoder) (*value, error) {
	token, err := decoder.Token()
	if err != nil {
		return nil, err
	}
	switch typed := token.(type) {
	case nil:
		return &value{kind: kindNull}, nil
	case bool:
		return &value{kind: kindBool, boolVal: typed}, nil
	case json.Number:
		return &value{kind: kindNumber, raw: typed.String()}, nil
	case string:
		return &value{kind: kindString, raw: typed}, nil
	case json.Delim:
		switch typed {
		case '[':
			items := make([]*value, 0)
			for decoder.More() {
				item, err := parseValue(decoder)
				if err != nil {
					return nil, err
				}
				items = append(items, item)
			}
			if end, err := decoder.Token(); err != nil || end != json.Delim(']') {
				if err != nil {
					return nil, err
				}
				return nil, fmt.Errorf("expected array end")
			}
			return &value{kind: kindArray, array: items}, nil
		case '{':
			entries := make([]objectEntry, 0)
			for decoder.More() {
				keyToken, err := decoder.Token()
				if err != nil {
					return nil, err
				}
				key, ok := keyToken.(string)
				if !ok {
					return nil, fmt.Errorf("expected object key")
				}
				child, err := parseValue(decoder)
				if err != nil {
					return nil, err
				}
				entries = append(entries, objectEntry{key: key, value: child})
			}
			if end, err := decoder.Token(); err != nil || end != json.Delim('}') {
				if err != nil {
					return nil, err
				}
				return nil, fmt.Errorf("expected object end")
			}
			return &value{kind: kindObject, object: entries}, nil
		}
	}
	return nil, fmt.Errorf("unexpected JSON token")
}

func valueToString(item *value) string {
	if item == nil {
		return ""
	}
	switch item.kind {
	case kindNull:
		return ""
	case kindBool:
		if item.boolVal {
			return "true"
		}
		return "false"
	case kindNumber:
		raw := item.raw
		if strings.ContainsAny(raw, ".eE") {
			return strings.ToLower(raw)
		}
		if parsed, ok := parseInt128ish(raw); ok {
			return parsed
		}
		return raw
	case kindString:
		return item.raw
	case kindArray:
		rendered := make([]string, 0, len(item.array))
		for _, child := range item.array {
			rendered = append(rendered, valueToString(child))
		}
		return "[" + strings.Join(rendered, ", ") + "]"
	case kindObject:
		rendered := make([]string, 0, len(item.object))
		for _, entry := range item.object {
			rendered = append(rendered, entry.key+"="+valueToString(entry.value))
		}
		return "{" + strings.Join(rendered, ", ") + "}"
	default:
		return ""
	}
}

func parseInt128ish(raw string) (string, bool) {
	if raw == "" {
		return "", false
	}
	start := 0
	negative := false
	if raw[0] == '-' {
		negative = true
		start = 1
		if len(raw) == 1 {
			return "", false
		}
	}
	for i := start; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return "", false
		}
	}
	digits := strings.TrimLeft(raw[start:], "0")
	if digits == "" {
		digits = "0"
		negative = false
	}
	max := "170141183460469231731687303715884105727"
	minAbs := "170141183460469231731687303715884105728"
	limit := max
	if negative {
		limit = minAbs
	}
	if len(digits) > len(limit) || (len(digits) == len(limit) && digits > limit) {
		return "", false
	}
	if negative {
		return "-" + digits, true
	}
	return digits, true
}

func objectLookup(key string, item *value) *value {
	if item == nil || item.kind != kindObject {
		return nullValue
	}
	for _, entry := range item.object {
		if entry.key == key {
			return entry.value
		}
	}
	return nullValue
}

func truthy(item *value) bool {
	if item == nil {
		return false
	}
	switch item.kind {
	case kindNull:
		return false
	case kindBool:
		return item.boolVal
	case kindNumber:
		raw := item.raw
		if strings.ContainsAny(raw, ".eE") {
			parsed, err := strconv.ParseFloat(raw, 64)
			return err == nil && parsed != 0
		}
		if parsed, ok := parseInt64ForTruth(raw); ok {
			return parsed != 0
		}
		return false
	default:
		return valueToString(item) != ""
	}
}

func parseInt64ForTruth(raw string) (int64, bool) {
	parsed, err := strconv.ParseInt(raw, 10, 64)
	if err == nil {
		return parsed, true
	}
	return 0, false
}

func allDigits(text string) bool {
	for i := 0; i < len(text); i++ {
		if text[i] < '0' || text[i] > '9' {
			return false
		}
	}
	return true
}

func looksDateOnly(text string) bool {
	return len(text) == 10 &&
		allDigits(text[0:4]) &&
		text[4:5] == "-" &&
		allDigits(text[5:7]) &&
		text[7:8] == "-" &&
		allDigits(text[8:10])
}

func leapYear(year int64) bool {
	return year%4 == 0 && (year%100 != 0 || year%400 == 0)
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

func parseZoneHours(zone string) float64 {
	if len(zone) != 5 {
		return 0
	}
	signByte := zone[0]
	if signByte != '+' && signByte != '-' {
		return 0
	}
	if !allDigits(zone[1:5]) {
		return 0
	}
	sign := 1.0
	if signByte == '-' {
		sign = -1.0
	}
	hours, _ := strconv.ParseInt(zone[1:3], 10, 64)
	minutes, _ := strconv.ParseInt(zone[3:5], 10, 64)
	return -(sign * (float64(hours) + float64(minutes)/60.0))
}

func divEuclid(a, b int64) int64 {
	q := a / b
	r := a % b
	if r < 0 {
		q--
	}
	return q
}

func daysFromCivil(year, month, day int64) int64 {
	y := year
	if month <= 2 {
		y--
	}
	era := divEuclid(y, 400)
	yoe := y - era*400
	mp := month + 9
	if month > 2 {
		mp = month - 3
	}
	doy := divEuclid(153*mp+2, 5) + day - 1
	doe := yoe*365 + divEuclid(yoe, 4) - divEuclid(yoe, 100) + doy
	return era*146097 + doe - 719468
}

func dateToTime(text string, zoneHours float64) (int64, error) {
	if !looksDateOnly(text) {
		return 0, fail(fmt.Sprintf("parsing time %q as \"2006-01-02\": cannot parse %q as \"2006\"", text, text))
	}
	year, _ := strconv.ParseInt(text[0:4], 10, 64)
	month, _ := strconv.ParseInt(text[5:7], 10, 64)
	day, _ := strconv.ParseInt(text[8:10], 10, 64)
	if year < 1 || year > 9999 {
		return 0, fail(fmt.Sprintf("year %d is out of range", year))
	}
	if month < 1 || month > 12 {
		return 0, fail("month must be in 1..12")
	}
	if day < 1 || day > daysInMonth(year, month) {
		return 0, fail(fmt.Sprintf("parsing time %q: day out of range", text))
	}
	return daysFromCivil(year, month, day)*86400 + int64(zoneHours*3600.0), nil
}

func localStartOfToday() (int64, error) {
	command := exec.Command("date", "+%Y-%m-%dT00:00:00%z")
	output, err := command.Output()
	if err != nil {
		return 0, err
	}
	trimmed := strings.Trim(string(output), "\n\r \t")
	date := "1970-01-01"
	if len(trimmed) >= 10 {
		date = trimmed[0:10]
	}
	zone := "+0000"
	if len(trimmed) >= 24 {
		zone = trimmed[19:24]
	}
	return dateToTime(date, parseZoneHours(zone))
}

func fetchURL(url string) (string, error) {
	response, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode > 299 {
		return "", fail(fmt.Sprintf("bad status: %d", response.StatusCode))
	}
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return "", err
	}
	return string(body), nil
}

func compareJSONValues(left, right *value) int {
	if left != nil && right != nil && left.kind == kindNumber && right.kind == kindNumber {
		leftValue, leftErr := strconv.ParseFloat(left.raw, 64)
		if leftErr != nil {
			leftValue = 0
		}
		rightValue, rightErr := strconv.ParseFloat(right.raw, 64)
		if rightErr != nil {
			rightValue = 0
		}
		if math.IsNaN(leftValue) || math.IsNaN(rightValue) || leftValue == rightValue {
			return 0
		}
		if leftValue < rightValue {
			return -1
		}
		return 1
	}
	return strings.Compare(valueToString(left), valueToString(right))
}

func summarize(today int64, todos []*value) ([]summary, error) {
	summaries := make([]summary, 0)
	for _, todo := range todos {
		userID := objectLookup("userId", todo)
		key := valueToString(userID)
		index := -1
		for i := range summaries {
			if valueToString(summaries[i].userID) == key {
				index = i
				break
			}
		}
		if index == -1 {
			summaries = append(summaries, summary{userID: userID})
			index = len(summaries) - 1
		}
		if truthy(objectLookup("completed", todo)) {
			summaries[index].completed++
		} else {
			dueText := valueToString(objectLookup("dueDate", todo))
			due, err := dateToTime(dueText, 0)
			if err != nil {
				return nil, err
			}
			if due < today {
				summaries[index].missed++
			}
		}
	}
	sort.SliceStable(summaries, func(i, j int) bool {
		left := summaries[i]
		right := summaries[j]
		if left.completed != right.completed {
			return left.completed > right.completed
		}
		if left.missed != right.missed {
			return left.missed > right.missed
		}
		return compareJSONValues(left.userID, right.userID) < 0
	})
	return summaries, nil
}

func writePadded(buffer *bytes.Buffer, text string, width int) {
	buffer.WriteString(text)
	if len(text) < width {
		buffer.WriteString(strings.Repeat(" ", width-len(text)))
	}
}

func run(args []string) (int, error) {
	if len(args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ./run.sh <url>")
		return 2, nil
	}
	body, err := fetchURL(args[1])
	if err != nil {
		return 0, err
	}
	root, err := parseJSON(body)
	if err != nil {
		return 0, err
	}
	if root.kind != kindArray {
		return 0, fail("expected JSON array")
	}
	today, err := localStartOfToday()
	if err != nil {
		return 0, err
	}
	rows, err := summarize(today, root.array)
	if err != nil {
		return 0, err
	}
	var output bytes.Buffer
	output.WriteString("USER  COMPLETED  MISSED\n")
	for _, row := range rows {
		writePadded(&output, valueToString(row.userID), 5)
		output.WriteByte(' ')
		writePadded(&output, strconv.FormatInt(row.completed, 10), 10)
		output.WriteString(fmt.Sprintf(" %d\n", row.missed))
	}
	fmt.Print(output.String())
	return 0, nil
}

func main() {
	code, err := run(os.Args)
	if err != nil {
		if err.Error() != "" {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
	os.Exit(code)
}
