#!/bin/bash

# Check if a directory path is provided
if [ $# -ne 1 ]; then
    echo "Usage: $0 <directory_path>"
    exit 1
fi

# Get the directory path from the command line argument
directory_path="$1"

# Check if the directory exists
if [ ! -d "$directory_path" ]; then
    echo "Error: Directory '$directory_path' does not exist."
    exit 1
fi

# Create a directory for storing vector representations if it doesn't exist
output_dir="${directory_path}/vectors"
mkdir -p "$output_dir"

echo "Processing images in directory: $directory_path"

# Common image file extensions
image_extensions=("jpg" "jpeg" "png" "gif" "bmp" "tiff" "webp")

# Function to check if a file has an image extension
is_image_file() {
    local file="$1"
    local ext="${file##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

    for valid_ext in "${image_extensions[@]}"; do
        if [ "$ext" = "$valid_ext" ]; then
            return 0
        fi
    done
    return 1
}

get_mime_type() {
    local ext="${1##*.}"
    ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
    case "$ext" in
        jpg|jpeg) echo "image/jpeg" ;;
        png)      echo "image/png" ;;
        gif)      echo "image/gif" ;;
        bmp)      echo "image/bmp" ;;
        tiff)     echo "image/tiff" ;;
        webp)     echo "image/webp" ;;
        *)        echo "image/jpeg" ;;
    esac
}

# Process each file in the directory
for file in "$directory_path"/*; do
    # Skip if not a file or not an image file
    if [ ! -f "$file" ] || ! is_image_file "$file"; then
        continue
    fi
    
    filename=$(basename "$file")
    echo "Processing image: $filename"
    
    # Convert image to Base64
    base64_data=$(base64 -i "$file" | tr -d '\n')
    mime_type=$(get_mime_type "$file")

    encoder_url="${ENCODER_URL:-http://localhost:8080/v1/embeddings}"

    # Send the Base64-encoded image to the API endpoint
    http_response=$(curl -s -w "\n%{http_code}" -X POST "$encoder_url" \
        -H "Content-Type: application/json" \
        -d "{\"input\": [{\"type\": \"image_url\", \"image_url\": {\"url\": \"data:${mime_type};base64,${base64_data}\"}}], \"task\": \"retrieval.passage\"}")

    http_code=$(echo "$http_response" | tail -n1)
    response=$(echo "$http_response" | sed '$d')

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Error: Failed to encode image $filename. HTTP status code: $http_code"
        echo "Response: $response"
        exit 1
    fi

    # Save the vector representation to a file
    echo "$response" > "${output_dir}/${filename%.*}.json"
    
    echo "Vector representation saved to: ${output_dir}/${filename%.*}.json"
done

echo "All images processed successfully."