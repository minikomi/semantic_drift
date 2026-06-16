package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"
)

const defaultAddr = "127.0.0.1:8899"

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
		DueDate:   "2026-06-10",
	},
	{
		UserID:    1,
		ID:        2,
		Title:     "quis ut nam facilis et officia qui",
		Completed: true,
		DueDate:   "2026-06-17",
	},
	{
		UserID:    2,
		ID:        3,
		Title:     "fugiat veniam minus",
		Completed: true,
		DueDate:   "2026-06-01",
	},
	{
		UserID:    2,
		ID:        4,
		Title:     "et porro tempora",
		Completed: true,
		DueDate:   "2026-06-16",
	},
	{
		UserID:    2,
		ID:        5,
		Title:     "laboriosam mollitia et enim quasi adipisci",
		Completed: false,
		DueDate:   "2026-06-15",
	},
}

func main() {
	addr := os.Getenv("SEMANTIC_DRIFT_ADDR")
	if addr == "" {
		addr = defaultAddr
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", healthHandler)
	mux.HandleFunc("GET /todos", todosHandler)

	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("semantic drift fake API listening on http://%s", addr)
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatal(err)
	}
}

func healthHandler(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
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
