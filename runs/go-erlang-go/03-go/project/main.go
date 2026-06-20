package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"time"

	"github.com/go-resty/resty/v2"
)

type todo struct {
	UserID    int    `json:"userId"`
	Completed bool   `json:"completed"`
	DueDate   string `json:"dueDate"`
}

type row struct {
	UserID    int
	Completed int
	Missed    int
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <todos-url>\n", os.Args[0])
		os.Exit(1)
	}

	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func run(url string) error {
	client := resty.New().
		SetTimeout(10 * time.Second)

	resp, err := client.R().Get(url)
	if err != nil {
		return err
	}
	if resp.StatusCode() < 200 || resp.StatusCode() >= 300 {
		return fmt.Errorf("bad status: %s", resp.Status())
	}

	var todos []todo
	if err := json.Unmarshal(resp.Body(), &todos); err != nil {
		return err
	}

	rows, err := summarize(todos, today())
	if err != nil {
		return err
	}
	printRows(rows)
	return nil
}

func today() time.Time {
	now := time.Now()
	return time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
}

func summarize(todos []todo, today time.Time) ([]row, error) {
	byUser := make(map[int]row)
	for _, item := range todos {
		current, ok := byUser[item.UserID]
		if !ok {
			current = row{UserID: item.UserID}
		}

		if item.Completed {
			current.Completed++
		} else {
			due, err := parseDate(item.DueDate, today.Location())
			if err != nil {
				return nil, err
			}
			if due.Before(today) {
				current.Missed++
			}
		}
		byUser[item.UserID] = current
	}

	rows := make([]row, 0, len(byUser))
	for _, item := range byUser {
		rows = append(rows, item)
	}
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.Completed != b.Completed {
			return a.Completed > b.Completed
		}
		if a.Missed != b.Missed {
			return a.Missed > b.Missed
		}
		return a.UserID <= b.UserID
	})
	return rows, nil
}

func parseDate(value string, loc *time.Location) (time.Time, error) {
	if len(value) != len("2006-01-02") {
		return time.Time{}, badDate(value)
	}
	parsed, err := time.ParseInLocation("2006-01-02", value, loc)
	if err != nil {
		return time.Time{}, badDate(value)
	}
	return parsed, nil
}

func badDate(value string) error {
	if value == "" {
		return errors.New("{bad_date,<<>>}")
	}
	return fmt.Errorf("{bad_date,<<\"%s\">>}", value)
}

func printRows(rows []row) {
	fmt.Println("USER  COMPLETED  MISSED")
	for _, item := range rows {
		fmt.Printf("%-5d %-10d %d\n", item.UserID, item.Completed, item.Missed)
	}
}
