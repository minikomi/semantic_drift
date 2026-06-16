package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"sort"
	"time"
)

type Todo struct {
	UserID    int    `json:"userId"`
	ID        int    `json:"id"`
	Completed bool   `json:"completed"`
	DueDate   string `json:"dueDate"`
}

type Summary struct {
	UserID    int
	Completed int
	Missed    int
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <todos-url>\n", os.Args[0])
		os.Exit(1)
	}

	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		fmt.Fprintf(os.Stderr, "bad status: %s\n", resp.Status)
		os.Exit(1)
	}

	var todos []Todo
	if err := json.NewDecoder(resp.Body).Decode(&todos); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	now := time.Now()
	y, m, d := now.Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, now.Location())

	byUser := map[int]*Summary{}
	for _, t := range todos {
		s := byUser[t.UserID]
		if s == nil {
			s = &Summary{UserID: t.UserID}
			byUser[t.UserID] = s
		}
		if t.Completed {
			s.Completed++
		} else {
			due, err := time.Parse(time.DateOnly, t.DueDate)
			if err != nil {
				fmt.Fprintln(os.Stderr, err)
				os.Exit(1)
			}
			if due.Before(today) {
				s.Missed++
			}
		}
	}

	rows := make([]Summary, 0, len(byUser))
	for _, s := range byUser {
		rows = append(rows, *s)
	}
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.Completed != b.Completed {
			return a.Completed > b.Completed
		}
		if a.Missed != b.Missed {
			return a.Missed > b.Missed
		}
		return a.UserID < b.UserID
	})

	fmt.Println("USER  COMPLETED  MISSED")
	for _, s := range rows {
		fmt.Printf("%-5d %-10d %d\n", s.UserID, s.Completed, s.Missed)
	}
}