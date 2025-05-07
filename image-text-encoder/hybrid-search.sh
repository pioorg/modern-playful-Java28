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

# Perform classic search in Elasticsearch (matching file name)
classic_http_response=$(curl -k -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey $ES_API_KEY" \
    "${ES_URL}/${index_name}/_search" \
    -d '{
        "size": 5,
        "query": {
            "match": {
                "full-path": "'"$search_text"'"
            }
        }
    }')

classic_http_code=$(echo "$classic_http_response" | tail -n1)
classic_search_response=$(echo "$classic_http_response" | sed '$d')

if [ "$classic_http_code" -lt 200 ] || [ "$classic_http_code" -ge 300 ]; then
    echo "Error: Failed to perform classic search in Elasticsearch. HTTP status code: $classic_http_code"
    echo "Response: $classic_search_response"
    exit 1
fi

# Perform vector search in Elasticsearch
vector_http_response=$(curl -k -s -w "\n%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: ApiKey $ES_API_KEY" \
    "${ES_URL}/${index_name}/_search" \
    -d '{
        "size": 5,
        "query": {
            "knn": {
                "field": "embedding",
                "query_vector": '"${vector}"',
                "k": 5,
                "num_candidates": 100
            }
        }
    }')

vector_http_code=$(echo "$vector_http_response" | tail -n1)
vector_search_response=$(echo "$vector_http_response" | sed '$d')

if [ "$vector_http_code" -lt 200 ] || [ "$vector_http_code" -ge 300 ]; then
    echo "Error: Failed to perform vector search in Elasticsearch. HTTP status code: $vector_http_code"
    echo "Response: $vector_search_response"
    exit 1
fi

# Extract results from both searches
if command -v jq &> /dev/null; then
    # Extract classic search results
    classic_hits=$(echo "$classic_search_response" | jq -c '.hits.hits')
    classic_count=$(echo "$classic_hits" | jq 'length')

    # Extract vector search results
    vector_hits=$(echo "$vector_search_response" | jq -c '.hits.hits')
    vector_count=$(echo "$vector_hits" | jq 'length')

    # Combine results using RRF (Reciprocal Rank Fusion)
    # Create temporary files to store document IDs, scores, and paths
    scores_file=$(mktemp)
    paths_file=$(mktemp)

    # Process classic search results
    for i in $(seq 0 $(($classic_count - 1))); do
        doc_id=$(echo "$classic_hits" | jq -r ".[$i]._id")
        full_path=$(echo "$classic_hits" | jq -r ".[$i]._source.\"full-path\"")
        rank=$(($i + 1))
        # RRF formula: 1/(k + rank) where k is a constant (typically 60)
        score=$(echo "scale=6; 1/(60 + $rank)" | bc)
        echo "$doc_id $score" >> "$scores_file"
        echo "$doc_id $full_path" >> "$paths_file"
    done

    # Process vector search results
    for i in $(seq 0 $(($vector_count - 1))); do
        doc_id=$(echo "$vector_hits" | jq -r ".[$i]._id")
        full_path=$(echo "$vector_hits" | jq -r ".[$i]._source.\"full-path\"")
        rank=$(($i + 1))
        # RRF formula: 1/(k + rank) where k is a constant (typically 60)
        score=$(echo "scale=6; 1/(60 + $rank)" | bc)

        # Check if document already exists in scores_file
        existing_score=$(grep "^$doc_id " "$scores_file" | awk '{print $2}')
        if [ -n "$existing_score" ]; then
            # Add the new score to the existing score
            new_score=$(echo "scale=6; $existing_score + $score" | bc)
            # Update the score in the scores_file
            sed -i.bak "s/^$doc_id $existing_score/$doc_id $new_score/" "$scores_file"
            rm -f "$scores_file.bak"
        else
            # Add new document to scores_file and paths_file
            echo "$doc_id $score" >> "$scores_file"
            echo "$doc_id $full_path" >> "$paths_file"
        fi
    done

    # Sort documents by combined score (descending) and take top 5
    sorted_docs=$(sort -k2,2 -nr "$scores_file" | head -5)

    # Display the results
    echo "Top matching images (hybrid search):"
    echo "=================================="

    rank=1
    while read -r doc_id score; do
        # Look up the document path from paths_file
        full_path=$(grep "^$doc_id " "$paths_file" | awk '{print $2}')
        echo "$rank. $full_path (RRF Score: $score)"
        rank=$((rank + 1))
    done <<< "$sorted_docs"

    if [ $rank -eq 1 ]; then
        echo "No matching images found."
    fi

    # Clean up temporary files
    rm -f "$scores_file" "$paths_file"
else
    # Fallback if jq is not available
    echo "Error: jq is required for hybrid search. Please install jq."
    exit 1
fi

echo "=================================="
echo "Search completed."
