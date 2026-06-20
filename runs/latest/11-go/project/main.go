package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"sort"
	"strconv"
	"strings"
	"time"
)

type appErrorKind int

const (
	errBadStatus appErrorKind = iota
	errExpectedJSONArray
	errMissingKey
	errBadDate
	errRequestFailed
)

type appError struct {
	kind    appErrorKind
	status  int
	reason  string
	key     string
	value   string
	message string
}

type summary struct {
	userID    any
	key       string
	completed int64
	missed    int64
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprint(os.Stderr, "usage: todo-summary <todos-url>\n")
		os.Exit(1)
	}

	if err := run(os.Args[1]); err != nil {
		var appErr appError
		if errors.As(err, &appErr) {
			switch appErr.kind {
			case errBadStatus:
				if appErr.reason != "" {
					fmt.Fprintf(os.Stderr, "bad status: %d %s\n", appErr.status, appErr.reason)
				} else {
					fmt.Fprintf(os.Stderr, "bad status: %d\n", appErr.status)
				}
			case errExpectedJSONArray:
				fmt.Fprintln(os.Stderr, "expected JSON array")
			case errMissingKey:
				fmt.Fprintf(os.Stderr, "key '%s' not found\n", appErr.key)
			case errBadDate:
				fmt.Fprintf(os.Stderr, "parsing time %q as %q: cannot parse %q as %q\n", appErr.value, "2006-01-02", appErr.value, "2006")
			case errRequestFailed:
				fmt.Fprintln(os.Stderr, appErr.message)
			}
		} else {
			fmt.Fprintln(os.Stderr, err.Error())
		}
		os.Exit(1)
	}
}

func (e appError) Error() string {
	return e.message
}

func run(rawURL string) error {
	response, err := httpGet(rawURL)
	if err != nil {
		return err
	}
	if response.status < 200 || response.status >= 300 {
		return appError{kind: errBadStatus, status: response.status, reason: reasonPhrase(response.status)}
	}

	decoder := json.NewDecoder(bytes.NewReader(response.body))
	decoder.UseNumber()
	var todos any
	if err := decoder.Decode(&todos); err != nil {
		return appError{kind: errRequestFailed, message: err.Error()}
	}

	rows, err := foldTodos(localMidnightNow(), todos)
	if err != nil {
		return err
	}
	sort.Slice(rows, func(i, j int) bool {
		return summaryLess(rows[i], rows[j])
	})

	fmt.Print("USER  COMPLETED  MISSED\n")
	for _, row := range rows {
		user := displayValue(row.userID)
		padRightStdout(5, user)
		fmt.Print(" ")
		padRightStdout(10, strconv.FormatInt(row.completed, 10))
		fmt.Printf(" %d\n", row.missed)
	}
	return nil
}

type httpResponse struct {
	body   []byte
	status int
}

func httpGet(rawURL string) (httpResponse, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return httpResponse{}, appError{kind: errRequestFailed, message: err.Error()}
	}
	resp, err := http.Get(parsed.String())
	if err != nil {
		return httpResponse{}, appError{kind: errRequestFailed, message: err.Error()}
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return httpResponse{}, appError{kind: errRequestFailed, message: err.Error()}
	}
	return httpResponse{body: body, status: resp.StatusCode}, nil
}

func reasonPhrase(status int) string {
	switch status {
	case 400:
		return "Bad Request"
	case 401:
		return "Unauthorized"
	case 402:
		return "Payment Required"
	case 403:
		return "Forbidden"
	case 404:
		return "Not Found"
	case 405:
		return "Method Not Allowed"
	case 406:
		return "Not Acceptable"
	case 407:
		return "Proxy Authentication Required"
	case 408:
		return "Request Timeout"
	case 409:
		return "Conflict"
	case 410:
		return "Gone"
	case 411:
		return "Length Required"
	case 412:
		return "Precondition Failed"
	case 413:
		return "Payload Too Large"
	case 414:
		return "URI Too Long"
	case 415:
		return "Unsupported Media Type"
	case 416:
		return "Range Not Satisfiable"
	case 417:
		return "Expectation Failed"
	case 421:
		return "Misdirected Request"
	case 426:
		return "Upgrade Required"
	case 429:
		return "Too Many Requests"
	case 500:
		return "Internal Server Error"
	case 501:
		return "Not Implemented"
	case 502:
		return "Bad Gateway"
	case 503:
		return "Service Unavailable"
	case 504:
		return "Gateway Timeout"
	case 505:
		return "HTTP Version Not Supported"
	default:
		return ""
	}
}

func foldTodos(today int64, todos any) ([]summary, error) {
	items, ok := todos.([]any)
	if !ok {
		return nil, appError{kind: errExpectedJSONArray}
	}

	var rows []summary
	keys := map[string]int{}
	for _, todo := range items {
		userID, err := required(todo, "userId")
		if err != nil {
			return nil, err
		}
		completed, err := required(todo, "completed")
		if err != nil {
			return nil, err
		}
		dueDate, err := required(todo, "dueDate")
		if err != nil {
			return nil, err
		}

		key := jsonKey(userID)
		index, ok := keys[key]
		if !ok {
			index = len(rows)
			keys[key] = index
			rows = append(rows, summary{userID: cloneJSONValue(userID), key: key})
		}

		if asBoolean(completed) {
			rows[index].completed++
		} else {
			text := displayValue(dueDate)
			due, err := parseDateOnlyInLocalTime(text)
			if err != nil {
				return nil, err
			}
			if due < today {
				rows[index].missed++
			}
		}
	}
	return rows, nil
}

func required(todo any, field string) (any, error) {
	object, ok := todo.(map[string]any)
	if !ok {
		return nil, appError{kind: errMissingKey, key: field}
	}
	value, ok := object[field]
	if !ok {
		return nil, appError{kind: errMissingKey, key: field}
	}
	return value, nil
}

func asBoolean(value any) bool {
	switch v := value.(type) {
	case bool:
		return v
	case string:
		return v == "true"
	case json.Number:
		return numberIsOne(v)
	default:
		return false
	}
}

func numberIsOne(value json.Number) bool {
	if n, err := value.Int64(); err == nil && n == 1 {
		return true
	}
	if n, ok := parseUint64(value.String()); ok && n == 1 {
		return true
	}
	if n, err := strconv.ParseFloat(value.String(), 64); err == nil && n == 1.0 {
		return true
	}
	return false
}

func displayValue(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case json.Number:
		return displayNumber(v)
	case bool:
		return strconv.FormatBool(v)
	case nil:
		return ""
	default:
		return jsonKey(v)
	}
}

func displayNumber(value json.Number) string {
	if n, err := value.Int64(); err == nil {
		return strconv.FormatInt(n, 10)
	}
	if n, ok := parseUint64(value.String()); ok {
		return strconv.FormatUint(n, 10)
	}
	n, err := strconv.ParseFloat(value.String(), 64)
	if err == nil {
		if !math.IsInf(n, 0) && !math.IsNaN(n) && math.Trunc(n) == n {
			return strconv.FormatInt(int64(n), 10)
		}
		return strconv.FormatFloat(n, 'g', -1, 64)
	}
	return value.String()
}

func parseUint64(text string) (uint64, bool) {
	if strings.HasPrefix(text, "-") || strings.ContainsAny(text, ".eE") {
		return 0, false
	}
	n, err := strconv.ParseUint(text, 10, 64)
	return n, err == nil
}

func jsonKey(value any) string {
	var buffer bytes.Buffer
	encoder := json.NewEncoder(&buffer)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(value); err != nil {
		return ""
	}
	return strings.TrimSuffix(buffer.String(), "\n")
}

func cloneJSONValue(value any) any {
	return value
}

func parseDateOnlyInLocalTime(value string) (int64, error) {
	if len(value) != 10 || value[4] != '-' || value[7] != '-' {
		return 0, appError{kind: errBadDate, value: value}
	}
	for i := 0; i < len(value); i++ {
		if i == 4 || i == 7 {
			continue
		}
		if value[i] < '0' || value[i] > '9' {
			return 0, appError{kind: errBadDate, value: value}
		}
	}

	year, err := strconv.Atoi(value[0:4])
	if err != nil {
		return 0, appError{kind: errBadDate, value: value}
	}
	month, err := strconv.Atoi(value[5:7])
	if err != nil {
		return 0, appError{kind: errBadDate, value: value}
	}
	day, err := strconv.Atoi(value[8:10])
	if err != nil {
		return 0, appError{kind: errBadDate, value: value}
	}

	date := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.Local)
	if date.Year() != year || int(date.Month()) != month || date.Day() != day {
		return 0, appError{kind: errBadDate, value: value}
	}
	return date.Unix(), nil
}

func localMidnightNow() int64 {
	now := time.Now()
	date := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)
	return date.Unix()
}

func padRightStdout(width int, value string) {
	fmt.Print(value)
	if len(value) < width {
		fmt.Print(strings.Repeat(" ", width-len(value)))
	}
}

func summaryLess(a, b summary) bool {
	if a.completed != b.completed {
		return a.completed > b.completed
	}
	if a.missed != b.missed {
		return a.missed > b.missed
	}
	return compareUserID(a, b) < 0
}

func compareUserID(a, b summary) int {
	leftNumber, leftIsNumber := a.userID.(json.Number)
	rightNumber, rightIsNumber := b.userID.(json.Number)
	if leftIsNumber && rightIsNumber {
		if leftInt, leftErr := leftNumber.Int64(); leftErr == nil {
			if rightInt, rightErr := rightNumber.Int64(); rightErr == nil {
				return compareInt64(leftInt, rightInt)
			}
		}
		leftFloat, _ := strconv.ParseFloat(leftNumber.String(), 64)
		rightFloat, _ := strconv.ParseFloat(rightNumber.String(), 64)
		if leftFloat < rightFloat {
			return -1
		}
		if leftFloat > rightFloat {
			return 1
		}
		return 0
	}

	leftString, leftIsString := a.userID.(string)
	rightString, rightIsString := b.userID.(string)
	if leftIsString && rightIsString {
		return strings.Compare(leftString, rightString)
	}

	leftBool, leftIsBool := a.userID.(bool)
	rightBool, rightIsBool := b.userID.(bool)
	if leftIsBool && rightIsBool {
		if leftBool == rightBool {
			return 0
		}
		if !leftBool {
			return -1
		}
		return 1
	}

	return strings.Compare(a.key, b.key)
}

func compareInt64(a, b int64) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}
