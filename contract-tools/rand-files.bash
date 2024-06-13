#!/bin/bash
# Set the locale to C to handle byte data correctly
export LC_ALL=C

# Check if the number of files to generate is passed as an argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <number_of_files>"
    exit 1
fi

num_files=$1
folder_name=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)

# Create a directory with a random 6-character name
mkdir -p "$folder_name"

for ((i=0; i<num_files; i++)); do
    # Generate a random 6-character string
    file_name=$(cat /dev/urandom | tr -dc 'a-z' | fold -w 6 | head -n 1)
    # Write the string to a file named after the string inside the directory
    echo "$file_name" > "$folder_name/$file_name"
done

echo "Generated $num_files files in directory $folder_name"