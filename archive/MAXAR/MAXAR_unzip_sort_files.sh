#!/bin/bash

# Define source directory (current folder)
SOURCE_DIR="./rclone"

# Define destination directories
MONOCHROME_DIR="./Mono"
RGB_DIR="./RGB"

# Ensure destination directories exist
mkdir -p "$MONOCHROME_DIR"
mkdir -p "$RGB_DIR"

# Loop through all zip files in the source directory
for file in "$SOURCE_DIR"/*.zip; do
    # Check if file name contains "M00"
    if [[ "$file" == *P00.zip* ]]; then
        unzip -o "$file" -d "$MONOCHROME_DIR"
    
    # Check if file name contains "P00"
    elif [[ "$file" == *M00.zip* ]]; then
        unzip -o "$file" -d "$RGB_DIR"
    fi
done

echo "Unzipping complete!"

