package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"

	_ "github.com/microsoft/go-mssqldb"
)

type video struct {
	ID    string `json:"id"`
	Title string `json:"title"`
}

type videoStore interface {
	ping(context.Context) error
	list(context.Context) ([]video, error)
	add(context.Context, video) error
}

type sqlServerStore struct {
	db *sql.DB
}

func (s sqlServerStore) ping(ctx context.Context) error {
	return s.db.PingContext(ctx)
}

func (s sqlServerStore) list(ctx context.Context) ([]video, error) {
	rows, err := s.db.QueryContext(ctx, "SELECT id, title FROM dbo.videos ORDER BY id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	videos := make([]video, 0)
	for rows.Next() {
		var item video
		if err := rows.Scan(&item.ID, &item.Title); err != nil {
			return nil, err
		}
		videos = append(videos, item)
	}
	return videos, rows.Err()
}

func (s sqlServerStore) add(ctx context.Context, item video) error {
	_, err := s.db.ExecContext(ctx,
		"INSERT INTO dbo.videos (id, title) VALUES (@p1, @p2)",
		item.ID,
		item.Title,
	)
	return err
}

func newSQLServerStore(ctx context.Context, lookupEnv func(string) string) (*sql.DB, error) {
	endpoint := lookupEnv("DB_ENDPOINT")
	username := lookupEnv("DB_USERNAME")
	password := lookupEnv("DB_PASSWORD")
	database := lookupEnv("DB_NAME")
	port := lookupEnv("DB_PORT")
	if port == "" {
		port = "1433"
	}
	if endpoint == "" || username == "" || password == "" || database == "" {
		return nil, errors.New("DB_ENDPOINT, DB_USERNAME, DB_PASSWORD, and DB_NAME are required")
	}
	portNumber, err := strconv.Atoi(port)
	if err != nil || portNumber < 1 || portNumber > 65535 {
		return nil, fmt.Errorf("invalid DB_PORT %q", port)
	}

	dsn := &url.URL{
		Scheme: "sqlserver",
		User:   url.UserPassword(username, password),
		Host:   net.JoinHostPort(endpoint, port),
	}
	query := dsn.Query()
	query.Set("database", database)
	query.Set("encrypt", "true")
	dsn.RawQuery = query.Encode()

	db, err := sql.Open("sqlserver", dsn.String())
	if err != nil {
		return nil, fmt.Errorf("open SQL Server connection: %w", err)
	}
	db.SetMaxOpenConns(10)
	db.SetMaxIdleConns(5)
	db.SetConnMaxLifetime(5 * time.Minute)

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("connect to SQL Server: %w", err)
	}
	if _, err := db.ExecContext(ctx, `IF OBJECT_ID(N'dbo.videos', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.videos (
        id NVARCHAR(50) NOT NULL PRIMARY KEY,
        title NVARCHAR(500) NOT NULL
    )
END`); err != nil {
		db.Close()
		return nil, fmt.Errorf("initialize videos table: %w", err)
	}
	return db, nil
}

func newHandler(store videoStore) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" || r.Method != http.MethodGet {
			http.NotFound(w, r)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		databaseStatus := "Connected"
		if err := store.ping(ctx); err != nil {
			databaseStatus = "Unavailable"
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		page := template.Must(template.New("home").Parse(`<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Silly Demo | SQL Server</title>
  <style>
    :root { color-scheme: light; font-family: system-ui, sans-serif; background: #f3f6f8; color: #172b3a; }
    body { margin: 0; min-height: 100vh; display: grid; place-items: center; }
    main { width: min(640px, calc(100% - 40px)); padding: 36px; background: white; border: 1px solid #dce5eb; border-radius: 12px; box-shadow: 0 18px 50px #17384a14; }
    h1 { margin: 0 0 8px; font-size: 2rem; }
    p { line-height: 1.6; color: #4c6270; }
    .status { display: inline-block; margin: 20px 0; padding: 8px 12px; border-radius: 999px; background: #e5f6ed; color: #17643b; font-weight: 650; }
    .status.bad { background: #fff0e8; color: #943b18; }
    a { color: #075f8a; font-weight: 600; }
    code { background: #eef3f6; padding: 3px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <main>
    <h1>Silly Demo</h1>
    <p>The backend is running with an Azure SQL database.</p>
    <p class="status {{if eq .DatabaseStatus "Unavailable"}}bad{{end}}">Database: {{.DatabaseStatus}}</p>
    <p><a href="/videos">View saved videos</a></p>
    <p>Add a record with <code>POST /video?id=1&amp;title=hello</code>.</p>
  </main>
</body>
</html>`))
		if err := page.Execute(w, struct{ DatabaseStatus string }{DatabaseStatus: databaseStatus}); err != nil {
			log.Printf("render home page: %v", err)
		}
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if err := store.ping(ctx); err != nil {
			http.Error(w, "database unavailable", http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/videos", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		videos, err := store.list(r.Context())
		if err != nil {
			http.Error(w, "failed to list videos", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(videos); err != nil {
			log.Printf("encode videos response: %v", err)
		}
	})
	mux.HandleFunc("/video", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		item := video{ID: r.URL.Query().Get("id"), Title: r.URL.Query().Get("title")}
		if item.ID == "" || item.Title == "" {
			http.Error(w, "id and title are required", http.StatusBadRequest)
			return
		}
		if err := store.add(r.Context(), item); err != nil {
			http.Error(w, "failed to add video", http.StatusInternalServerError)
			return
		}
		_, _ = fmt.Fprintln(w, "Video added successfully")
	})
	return mux
}

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	db, err := newSQLServerStore(ctx, os.Getenv)
	if err != nil {
		log.Fatal(err)
	}
	defer db.Close()

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	server := &http.Server{
		Addr:              ":" + port,
		Handler:           newHandler(sqlServerStore{db: db}),
		ReadHeaderTimeout: 5 * time.Second,
	}
	log.Printf("SQL Server demo listening on %s", server.Addr)
	log.Fatal(server.ListenAndServe())
}
