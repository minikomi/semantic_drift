package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sort"
	"time"
)

const defaultAddr = "127.0.0.1:8899"

type conformanceRunner struct {
	expected []byte
}

type conformanceResponse struct {
	Passed  bool   `json:"passed"`
	Failure string `json:"failure,omitempty"`
}

type Todo struct {
	UserID    int    `json:"userId"`
	ID        int    `json:"id"`
	Title     string `json:"title"`
	Completed bool   `json:"completed"`
	DueDate   string `json:"dueDate"`
}

var todos = []Todo{
	{
		UserID:    1,
		ID:        1,
		Title:     "delectus aut autem",
		Completed: false,
		DueDate:   "1900-01-01",
	},
	{
		UserID:    1,
		ID:        2,
		Title:     "quis ut nam facilis et officia qui",
		Completed: true,
		DueDate:   "2999-12-31",
	},
	{
		UserID:    2,
		ID:        3,
		Title:     "fugiat veniam minus",
		Completed: true,
		DueDate:   "1950-06-15",
	},
	{
		UserID:    2,
		ID:        4,
		Title:     "et porro tempora",
		Completed: true,
		DueDate:   "2200-01-01",
	},
	{
		UserID:    2,
		ID:        5,
		Title:     "laboriosam mollitia et enim quasi adipisci",
		Completed: false,
		DueDate:   "1999-12-31",
	},
	{
		UserID:    3,
		ID:        6,
		Title:     "qui ullam ratione quibusdam voluptatem quia omnis",
		Completed: true,
		DueDate:   "2000-02-29",
	},
	{
		UserID:    3,
		ID:        7,
		Title:     "illo expedita consequatur quia in",
		Completed: true,
		DueDate:   "2500-07-01",
	},
	{
		UserID:    3,
		ID:        8,
		Title:     "quo adipisci enim quam ut ab",
		Completed: false,
		DueDate:   "1970-01-01",
	},
	{
		UserID:    3,
		ID:        9,
		Title:     "molestiae perspiciatis ipsa",
		Completed: false,
		DueDate:   "2001-09-09",
	},
	{
		UserID:    4,
		ID:        10,
		Title:     "illo est ratione doloremque quia maiores aut",
		Completed: true,
		DueDate:   "1969-07-20",
	},
	{
		UserID:    4,
		ID:        11,
		Title:     "vero rerum temporibus dolor",
		Completed: true,
		DueDate:   "2300-03-01",
	},
	{
		UserID:    4,
		ID:        12,
		Title:     "ipsa repellendus fugit nisi",
		Completed: false,
		DueDate:   "1985-10-26",
	},
	{
		UserID:    5,
		ID:        13,
		Title:     "et doloremque nulla",
		Completed: true,
		DueDate:   "2024-02-29",
	},
	{
		UserID:    5,
		ID:        14,
		Title:     "repellendus sunt dolores architecto voluptatum",
		Completed: false,
		DueDate:   "1918-11-11",
	},
	{
		UserID:    5,
		ID:        15,
		Title:     "ab voluptatum amet voluptas",
		Completed: false,
		DueDate:   "1945-09-02",
	},
	{
		UserID:    5,
		ID:        16,
		Title:     "accusamus eos facilis sint et aut voluptatem",
		Completed: false,
		DueDate:   "2000-01-01",
	},
	{
		UserID:    6,
		ID:        17,
		Title:     "quo laboriosam deleniti aut qui",
		Completed: false,
		DueDate:   "2100-01-01",
	},
	{
		UserID:    6,
		ID:        18,
		Title:     "dolorum est consequatur ea mollitia in culpa",
		Completed: false,
		DueDate:   "2400-02-29",
	},
	{
		UserID:    7,
		ID:        19,
		Title:     "molestiae ipsa aut voluptatibus pariatur dolor nihil",
		Completed: false,
		DueDate:   "1930-01-01",
	},
	{
		UserID:    7,
		ID:        20,
		Title:     "ullam nobis libero sapiente ad optio sint",
		Completed: false,
		DueDate:   "2999-01-01",
	},
}

func main() {
	addr := flag.String("addr", envOrDefault("SEMANTIC_DRIFT_ADDR", defaultAddr), "listen address")
	flag.Parse()

	runner, err := newConformanceRunner()
	if err != nil {
		log.Fatal(err)
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /todos", todosHandler)
	mux.HandleFunc("POST /conform", runner.handle)

	server := &http.Server{
		Addr:              *addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("semantic drift fake API listening on http://%s", *addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func newConformanceRunner() (*conformanceRunner, error) {
	expected, err := expectedOutput(todos, time.Now())
	if err != nil {
		return nil, fmt.Errorf("calculate expected output: %w", err)
	}
	return &conformanceRunner{expected: expected}, nil
}

func (runner *conformanceRunner) handle(w http.ResponseWriter, request *http.Request) {
	const maxOutputBytes = 1 << 20
	submitted, err := io.ReadAll(http.MaxBytesReader(w, request.Body, maxOutputBytes))
	if err != nil {
		writeJSON(w, http.StatusRequestEntityTooLarge, conformanceResponse{
			Failure: "submitted output is too large",
		})
		return
	}

	response := conformanceResponse{Passed: bytes.Equal(submitted, runner.expected)}
	if !response.Passed {
		response.Failure = "submitted output did not match expected output"
	}
	writeJSON(w, http.StatusOK, response)
}

func expectedOutput(todos []Todo, now time.Time) ([]byte, error) {
	y, m, d := now.Date()
	today := time.Date(y, m, d, 0, 0, 0, 0, now.Location())

	type summary struct {
		userID    int
		completed int
		missed    int
	}

	byUser := make(map[int]*summary)
	for _, todo := range todos {
		item := byUser[todo.UserID]
		if item == nil {
			item = &summary{userID: todo.UserID}
			byUser[todo.UserID] = item
		}
		if todo.Completed {
			item.completed++
			continue
		}

		due, err := time.ParseInLocation(time.DateOnly, todo.DueDate, today.Location())
		if err != nil {
			return nil, fmt.Errorf("parse due date %q: %w", todo.DueDate, err)
		}
		if due.Before(today) {
			item.missed++
		}
	}

	rows := make([]summary, 0, len(byUser))
	for _, item := range byUser {
		rows = append(rows, *item)
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

	var output bytes.Buffer
	fmt.Fprintln(&output, "USER  COMPLETED  MISSED")
	for _, row := range rows {
		fmt.Fprintf(&output, "%-5d %-10d %d\n", row.userID, row.completed, row.missed)
	}
	return output.Bytes(), nil
}

func envOrDefault(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"status":             "ok",
		"conformanceEnabled": true,
	})
}

func todosHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, todos)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("write response: %v", err)
	}
}
