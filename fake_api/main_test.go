package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestConformanceAcceptsExactSubmittedOutput(t *testing.T) {
	runner := conformanceRunner{expected: []byte("expected output\n")}
	request := httptest.NewRequest(http.MethodPost, "/conform", strings.NewReader("expected output\n"))
	response := httptest.NewRecorder()

	runner.handle(response, request)

	result := decodeConformanceResponse(t, response)
	if !result.Passed || result.Failure != "" {
		t.Fatalf("unexpected response: %+v", result)
	}
}

func TestConformanceRejectsDifferentSubmittedOutput(t *testing.T) {
	runner := conformanceRunner{expected: []byte("expected output\n")}
	request := httptest.NewRequest(http.MethodPost, "/conform", strings.NewReader("different output\n"))
	response := httptest.NewRecorder()

	runner.handle(response, request)

	result := decodeConformanceResponse(t, response)
	if result.Passed || result.Failure != "submitted output did not match expected output" {
		t.Fatalf("unexpected response: %+v", result)
	}
}

func TestConformanceRejectsOversizedOutput(t *testing.T) {
	runner := conformanceRunner{expected: nil}
	request := httptest.NewRequest(http.MethodPost, "/conform", bytes.NewReader(make([]byte, (1<<20)+1)))
	response := httptest.NewRecorder()

	runner.handle(response, request)

	if response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusRequestEntityTooLarge)
	}
	result := decodeConformanceResponse(t, response)
	if result.Passed || result.Failure != "submitted output is too large" {
		t.Fatalf("unexpected response: %+v", result)
	}
}

func decodeConformanceResponse(t *testing.T, recorder *httptest.ResponseRecorder) conformanceResponse {
	t.Helper()
	var result conformanceResponse
	if err := json.NewDecoder(recorder.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}
