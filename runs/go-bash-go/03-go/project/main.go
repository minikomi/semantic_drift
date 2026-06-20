package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"time"
)

type todo struct {
	UserID    int    `json:"userId"`
	Completed bool   `json:"completed"`
	DueDate   string `json:"dueDate"`
}

type userSummary struct {
	UserID    int
	Completed int
	Missed    int
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ./run.sh <url>")
		os.Exit(2)
	}

	body, err := fetch(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var todos []todo
	if err := json.Unmarshal(body, &todos); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	today := time.Now().Format("2006-01-02")
	summaries := summarize(todos, today)

	fmt.Println("USER  COMPLETED  MISSED")
	for _, summary := range summaries {
		fmt.Printf("%-5d %-10d %d\n", summary.UserID, summary.Completed, summary.Missed)
	}
}

func fetch(url string) ([]byte, error) {
	client := http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}

	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return nil, fmt.Errorf("bad status: %03d", resp.StatusCode)
	}

	return body, nil
}

func summarize(todos []todo, today string) []userSummary {
	byUser := make(map[int]*userSummary)
	for _, item := range todos {
		summary := byUser[item.UserID]
		if summary == nil {
			summary = &userSummary{UserID: item.UserID}
			byUser[item.UserID] = summary
		}

		if item.Completed {
			summary.Completed++
		} else if item.DueDate < today {
			summary.Missed++
		}
	}

	summaries := make([]userSummary, 0, len(byUser))
	for _, summary := range byUser {
		summaries = append(summaries, *summary)
	}

	sort.Slice(summaries, func(i, j int) bool {
		left, right := summaries[i], summaries[j]
		if left.Completed != right.Completed {
			return left.Completed > right.Completed
		}
		if left.Missed != right.Missed {
			return left.Missed > right.Missed
		}
		return left.UserID < right.UserID
	})

	return summaries
}
