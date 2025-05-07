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

# Check if Elasticsearch environment variables are set
if [ -z "$ES_URL" ] || [ -z "$ES_API_KEY" ]; then
    echo "Error: Elasticsearch environment variables ES_URL and ES_API_KEY must be set."
    echo "Example:"
    echo "export ES_URL=http://localhost:9200"
    echo "export ES_API_KEY=TFot....=="
    exit 1
fi

# Define the index name
index_name="catalogue"

# Create the index if it doesn't exist
index_exists=$(curl -k -s --connect-timeout 5 --max-time 120 -o /dev/null -w "%{http_code}" -X GET \
    -H "Authorization: ApiKey $ES_API_KEY" \
    "${ES_URL}/${index_name}")

if [ "$index_exists" != "200" ] && [ "$index_exists" != "404" ]; then
    echo "Error: Failed to check if index exists. HTTP status code: $index_exists"
    exit 1
fi

if [ "$index_exists" != "200" ]; then
    echo "Creating index: $index_name"

    # Define the index mapping with the required fields
    create_http_response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 5 --max-time 120 -X PUT \
        -H "Content-Type: application/json" \
        -H "Authorization: ApiKey $ES_API_KEY" \
        "${ES_URL}/${index_name}" \
        -d '{
            "mappings": {
                "properties": {
                    "filename": {
                        "type": "keyword"
                    },
                    "full-path": {
                        "type": "keyword"
                    },
                    "embedding": {
                        "type": "dense_vector",
                        "dims": 768
                    },
                    "@timestamp": {
                        "type": "date"
                    }
                }
            }
        }')

    create_http_code=$(echo "$create_http_response" | tail -n1)
    response=$(echo "$create_http_response" | sed '$d')

    if [ "$create_http_code" -lt 200 ] || [ "$create_http_code" -ge 300 ]; then
        echo "Error: Failed to create index. HTTP status code: $create_http_code"
        echo "Response: $response"
        exit 1
    fi

    echo "Index created successfully."
else
    echo "Index already exists: $index_name"
fi

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

    # Get the full path of the image
    full_path=$(realpath "$file")
    filename=$(basename "$file")

    echo "Processing image: $filename"

    # Convert image to Base64
    base64_data=$(base64 -i "$file" | tr -d '\n')
    mime_type=$(get_mime_type "$file")

    encoder_url="${ENCODER_URL:-http://localhost:8080/v1/embeddings}"

    # Send the Base64-encoded image to the API endpoint with a timeout
    http_response=$(curl -s -w "\n%{http_code}" --connect-timeout 5 --max-time 600 -X POST "$encoder_url" \
        -H "Content-Type: application/json" \
        -d "{\"input\": [{\"type\": \"image_url\", \"image_url\": {\"url\": \"data:${mime_type};base64,${base64_data}\"}}], \"task\": \"retrieval.passage\"}")

    http_code=$(echo "$http_response" | tail -n1)
    response=$(echo "$http_response" | sed '$d')

    if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
        echo "Error: Failed to get vector representation for $filename. HTTP status code: $http_code"
        echo "Response: $response"
        exit 1
    fi

    # Extract the embedding array from the JSON response
    if command -v jq &> /dev/null; then
        vector=$(echo "$response" | jq -c '.data[0].embedding')
        if [ -z "$vector" ] || [ "$vector" = "null" ]; then
            echo "Error: Failed to extract embedding from response for $filename."
            continue
        fi
    else
        echo "Error: jq is required. Please install jq for JSON parsing."
        exit 1
    fi

    # Get current datetime in UTC
    current_utc_datetime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Index the data into Elasticsearch with a timeout
    index_http_response=$(curl -k -s -w "\n%{http_code}" --connect-timeout 5 --max-time 120 -X POST \
        -H "Content-Type: application/json" \
        -H "Authorization: ApiKey $ES_API_KEY" \
        "${ES_URL}/${index_name}/_doc" \
-d '{
    "filename": "'"${filename}"'",
    "full-path": "'"${full_path}"'",
    "embedding": '"${vector}"',
    "@timestamp": "'"${current_utc_datetime}"'"
}')

    index_http_code=$(echo "$index_http_response" | tail -n1)
    response=$(echo "$index_http_response" | sed '$d')

    if [ "$index_http_code" -lt 200 ] || [ "$index_http_code" -ge 300 ]; then
        echo "Error: Failed to index vector for $filename. HTTP status code: $index_http_code"
        echo "Response: $response"
        exit 1
    fi

    echo "Vector indexed for: $filename"
    echo "===="
done

echo "All images processed and vectors imported successfully."
