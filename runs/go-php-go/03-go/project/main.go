package main

import (
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"
)

type row struct {
	userID    int
	completed int
	missed    int
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <todos-url>\n", os.Args[0])
		os.Exit(1)
	}

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		status := resp.Status
		if status == "" {
			status = strconv.Itoa(resp.StatusCode)
		}
		fmt.Fprintln(os.Stderr, "bad status: "+status)
		os.Exit(1)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	var decoded any
	if err := json.Unmarshal(body, &decoded); err != nil {
		fmt.Fprintln(os.Stderr, err.Error())
		os.Exit(1)
	}

	items, ok := phpArrayValues(decoded)
	if !ok {
		fmt.Fprintln(os.Stderr, "json: cannot unmarshal non-array into Go value of type []main.Todo")
		os.Exit(1)
	}

	now := time.Now()
	today := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.Local)

	byUser := map[int]*row{}
	for _, item := range items {
		todo, ok := item.(map[string]any)
		if !ok {
			todo = map[string]any{}
		}

		userID := phpInt(todo["userId"])
		r, exists := byUser[userID]
		if !exists {
			r = &row{userID: userID}
			byUser[userID] = r
		}

		if phpBool(todo["completed"]) {
			r.completed++
			continue
		}

		dueDate := phpString(todo["dueDate"])
		due, ok := parsePHPYMD(dueDate)
		if !ok {
			fmt.Fprintln(os.Stderr, parseDateError(dueDate))
			os.Exit(1)
		}
		if due.Before(today) {
			r.missed++
		}
	}

	rows := make([]row, 0, len(byUser))
	for _, r := range byUser {
		rows = append(rows, *r)
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].completed != rows[j].completed {
			return rows[i].completed > rows[j].completed
		}
		if rows[i].missed != rows[j].missed {
			return rows[i].missed > rows[j].missed
		}
		return rows[i].userID < rows[j].userID
	})

	fmt.Println("USER  COMPLETED  MISSED")
	for _, r := range rows {
		fmt.Printf("%-5d %-10d %d\n", r.userID, r.completed, r.missed)
	}
}

func phpArrayValues(v any) ([]any, bool) {
	switch x := v.(type) {
	case []any:
		return x, true
	case map[string]any:
		values := make([]any, 0, len(x))
		for _, value := range x {
			values = append(values, value)
		}
		return values, true
	default:
		return nil, false
	}
}

func phpInt(v any) int {
	switch x := v.(type) {
	case nil:
		return 0
	case bool:
		if x {
			return 1
		}
		return 0
	case float64:
		if math.IsNaN(x) || math.IsInf(x, 0) {
			return 0
		}
		return int(x)
	case string:
		return phpIntFromString(x)
	default:
		return 0
	}
}

func phpIntFromString(s string) int {
	t := strings.TrimLeft(s, " \t\n\r\v\f")
	if t == "" {
		return 0
	}
	i := 0
	if t[0] == '+' || t[0] == '-' {
		i++
	}
	startDigits := i
	for i < len(t) && t[i] >= '0' && t[i] <= '9' {
		i++
	}
	if i == startDigits {
		return 0
	}
	if i < len(t) && t[i] == '.' {
		i++
		for i < len(t) && t[i] >= '0' && t[i] <= '9' {
			i++
		}
	}
	if i < len(t) && (t[i] == 'e' || t[i] == 'E') {
		j := i + 1
		if j < len(t) && (t[j] == '+' || t[j] == '-') {
			j++
		}
		expStart := j
		for j < len(t) && t[j] >= '0' && t[j] <= '9' {
			j++
		}
		if j > expStart {
			i = j
		}
	}
	f, err := strconv.ParseFloat(t[:i], 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
	return int(f)
}

func phpBool(v any) bool {
	switch x := v.(type) {
	case nil:
		return false
	case bool:
		return x
	case float64:
		return x != 0
	case string:
		return x != "" && x != "0"
	case []any:
		return len(x) != 0
	case map[string]any:
		return len(x) != 0
	default:
		return true
	}
}

func phpString(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case bool:
		if x {
			return "1"
		}
		return ""
	case float64:
		if math.Trunc(x) == x {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'f', -1, 64)
	case []any, map[string]any:
		return "Array"
	default:
		rv := reflect.ValueOf(v)
		if rv.IsValid() && (rv.Kind() == reflect.Slice || rv.Kind() == reflect.Map) {
			return "Array"
		}
		return ""
	}
}

func parsePHPYMD(s string) (time.Time, bool) {
	if len(s) != len("2006-01-02") {
		return time.Time{}, false
	}
	for i, c := range s {
		if i == 4 || i == 7 {
			if c != '-' {
				return time.Time{}, false
			}
			continue
		}
		if c < '0' || c > '9' {
			return time.Time{}, false
		}
	}
	t, err := time.ParseInLocation("2006-01-02", s, time.Local)
	if err != nil {
		return time.Time{}, false
	}
	if t.Format("2006-01-02") != s {
		return time.Time{}, false
	}
	return t, true
}

func parseDateError(value string) string {
	if value == "" {
		return `parsing time "" as "2006-01-02": cannot parse "" as "2006"`
	}
	b, _ := json.Marshal(value)
	return fmt.Sprintf(`parsing time %s as "2006-01-02": cannot parse as date`, string(b))
}
