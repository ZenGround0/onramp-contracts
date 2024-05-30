package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type BufferFS struct {
	dir    string
	nextID int // to keep track of the next file ID
}

func NewBufferFS() *BufferFS {
	return &BufferFS{dir: os.TempDir(), nextID: 1}
}

type Buffer interface {
	Put(filepath string) (int, error)
	Get(id int) (io.Reader, error)
}

func (b *BufferFS) Put(r io.Reader) (int, error) {

	targetPath := filepath.Join(b.dir, fmt.Sprintf("%d", b.nextID))

	targetFile, err := os.Create(targetPath)
	if err != nil {
		return 0, err
	}
	defer targetFile.Close()

	if _, err := io.Copy(targetFile, r); err != nil {
		return 0, err
	}

	id := b.nextID
	b.nextID++

	return id, nil
}

func (b *BufferFS) Get(id int) (io.Reader, error) {

	filePath := filepath.Join(b.dir, fmt.Sprintf("%d", id))
	file, err := os.Open(filePath)
	if err != nil {
		return nil, err
	}

	// Schedule file deletion after it has been read
	defer func() {
		file.Close()
		os.Remove(filePath)
	}()

	return file, nil
}
