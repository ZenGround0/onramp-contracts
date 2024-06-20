#!/bin/bash
# Check if a file path is provided
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <file-path>"
    exit 1
fi

# Get the absolute path of the file
FILE_PATH=$(realpath $1)

# Check if the file exists
if [ ! -f "$FILE_PATH" ]; then
    echo "File does not exist: $FILE_PATH"
    exit 1
fi

# Get a random free port
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("", 0)); print(s.getsockname()[1]); s.close()')

# Start the HTTP server
echo "Hosting $FILE_PATH on http://localhost:$PORT"
python3 -m http.server --bind localhost $PORT --directory $(dirname "$FILE_PATH")