#!/bin/bash

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

# Ask the user what image they are looking for
echo "What image are you looking for?"
read search_text

echo "Searching for: $search_text"

encoder_url="${ENCODER_URL:-http://localhost:8080/v1/embeddings}"

# Send the text to the encoder service to get a vector representation
http_response=$(curl -s -w "\n%{http_code}" -X POST "$encoder_url" \
    -H "Content-Type: application/json" \
    -d "{\"input\": [\"$search_text\"], \"task\": \"retrieval.query\"}")

http_code=$(echo "$http_response" | tail -n1)
response=$(echo "$http_response" | sed '$d')

if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "Error: Failed to get vector representation from encoder service. HTTP status code: $http_code"
    echo "Response: $response"
    exit 1
fi

# Extract the embedding array from the JSON response
if command -v jq &> /dev/null; then
    vector=$(echo "$response" | jq -c '.data[0].embedding')
    if [ -z "$vector" ] || [ "$vector" = "null" ]; then
        echo "Error: Failed to extract embedding from response."
        exit 1
    fi
else
    echo "Error: jq is required. Please install jq for JSON parsing."
    exit 1
fi

# Perform vector search in Elasticsearch
search_http_response=$(curl -k -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey $ES_API_KEY" \
    "${ES_URL}/${index_name}/_search" \
    -d '{
        "size": 3,
        "query": {
            "knn": {
                "field": "embedding",
                "query_vector": '"${vector}"',
                "k": 5,
                "num_candidates": 100
            }
        }
    }')

search_http_code=$(echo "$search_http_response" | tail -n1)
search_response=$(echo "$search_http_response" | sed '$d')

if [ "$search_http_code" -lt 200 ] || [ "$search_http_code" -ge 300 ]; then
    echo "Error: Failed to search in Elasticsearch. HTTP status code: $search_http_code"
    echo "Response: $search_response"
    exit 1
fi

# Extract and display the results
echo "Top 3 matching images:"
echo "======================"

if command -v jq &> /dev/null; then
    # Use jq to extract the results
    hits=$(echo "$search_response" | jq -c '.hits.hits')
    count=$(echo "$hits" | jq 'length')

    if [ "$count" -eq 0 ]; then
        echo "No matching images found."
        exit 0
    fi

    for i in $(seq 0 $(($count - 1))); do
        full_path=$(echo "$hits" | jq -r ".[$i]._source.\"full-path\"")
        score=$(echo "$hits" | jq -r ".[$i]._score")
        echo "$(($i + 1)). $full_path (Score: $score)"
    done
else
    # Fallback to grep and sed if jq is not available
    echo "For better results, please install jq."
    echo "$search_response" | grep -o '"full-path":"[^"]*"' | sed 's/"full-path":"//;s/"//'
fi

echo "======================"
echo "Search completed."
