package main

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

type memoryStore struct {
	items []video
	err   error
}

func (s *memoryStore) ping(context.Context) error { return s.err }

func (s *memoryStore) list(context.Context) ([]video, error) {
	return append([]video(nil), s.items...), s.err
}

func (s *memoryStore) add(_ context.Context, item video) error {
	if s.err != nil {
		return s.err
	}
	s.items = append(s.items, item)
	return nil
}

func TestRootAndHealth(t *testing.T) {
	store := &memoryStore{}
	handler := newHandler(store)

	root := httptest.NewRecorder()
	handler.ServeHTTP(root, httptest.NewRequest(http.MethodGet, "/", nil))
	if root.Code != http.StatusOK || root.Header().Get("Content-Type") != "text/html; charset=utf-8" || !strings.Contains(root.Body.String(), "Database: Connected") || !strings.Contains(root.Body.String(), `href="/videos"`) {
		t.Fatalf("unexpected root response: status=%d body=%q", root.Code, root.Body.String())
	}

	health := httptest.NewRecorder()
	handler.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if health.Code != http.StatusOK {
		t.Fatalf("expected healthy status, got %d", health.Code)
	}

	store.err = errors.New("database unavailable")
	unhealthy := httptest.NewRecorder()
	handler.ServeHTTP(unhealthy, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if unhealthy.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected unavailable status, got %d", unhealthy.Code)
	}
	rootUnavailable := httptest.NewRecorder()
	handler.ServeHTTP(rootUnavailable, httptest.NewRequest(http.MethodGet, "/", nil))
	if rootUnavailable.Code != http.StatusServiceUnavailable || !strings.Contains(rootUnavailable.Body.String(), "Database: Unavailable") {
		t.Fatalf("expected unavailable home page, got status=%d body=%q", rootUnavailable.Code, rootUnavailable.Body.String())
	}
}

func TestVideoEndpoints(t *testing.T) {
	store := &memoryStore{}
	handler := newHandler(store)

	badRequest := httptest.NewRecorder()
	handler.ServeHTTP(badRequest, httptest.NewRequest(http.MethodPost, "/video?id=1", nil))
	if badRequest.Code != http.StatusBadRequest {
		t.Fatalf("expected bad request, got %d", badRequest.Code)
	}

	created := httptest.NewRecorder()
	handler.ServeHTTP(created, httptest.NewRequest(http.MethodPost, "/video?id=1&title=hello", nil))
	if created.Code != http.StatusOK {
		t.Fatalf("expected created response, got %d: %s", created.Code, created.Body.String())
	}

	listed := httptest.NewRecorder()
	handler.ServeHTTP(listed, httptest.NewRequest(http.MethodGet, "/videos", nil))
	if listed.Code != http.StatusOK || !strings.Contains(listed.Body.String(), `"title":"hello"`) {
		t.Fatalf("unexpected videos response: status=%d body=%q", listed.Code, listed.Body.String())
	}
}
