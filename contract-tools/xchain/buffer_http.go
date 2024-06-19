package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"

	"github.com/mitchellh/go-homedir"

	"strconv"
	"sync"
)

type BufferHTTPService struct {
	basePath string
	nextID   int
	mu       sync.Mutex
}

func NewBufferHTTPService(basePath string) (*BufferHTTPService, error) {
	path, err := homedir.Expand(basePath)
	if err != nil {
		return nil, err
	}
	return &BufferHTTPService{
		basePath: path,
		nextID:   1,
	}, nil
}

func (s *BufferHTTPService) PutHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != "POST" {
		http.Error(w, "Invalid method", http.StatusMethodNotAllowed)
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	filePath := filepath.Join(s.basePath, fmt.Sprintf("data_%d", s.nextID))
	file, err := os.Create(filePath)
	if err != nil {
		http.Error(w, fmt.Errorf("failed to create file %w", err).Error(), http.StatusInternalServerError)
		return
	}
	defer file.Close()

	_, err = io.Copy(file, r.Body)
	if err != nil {
		http.Error(w, "Failed to write data", http.StatusInternalServerError)
		return
	}

	id := s.nextID
	s.nextID++

	w.WriteHeader(http.StatusOK)
	w.Write([]byte(fmt.Sprintf("{\"id\": %d}", id)))
}

func (s *BufferHTTPService) GetHandler(w http.ResponseWriter, r *http.Request) {
	idStr := r.URL.Query().Get("id")
	if idStr == "" {
		http.Error(w, "ID is required", http.StatusBadRequest)
		return
	}

	id, err := strconv.Atoi(idStr)
	if err != nil {
		http.Error(w, "Invalid ID", http.StatusBadRequest)
		return
	}

	filePath := filepath.Join(s.basePath, fmt.Sprintf("data_%d", id))
	file, err := os.Open(filePath)
	if err != nil {
		http.Error(w, "No data found", http.StatusNotFound)
		return
	}
	defer file.Close()

	io.Copy(w, file)
}
