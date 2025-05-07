# Learning modern Java the playful way

Hi! \
This is a demo project for a talk by Marit and Piotr, showcasing modern Java 28 features. The repo contains two independent demos:

- **`searcher/`**: a multimodal image search demo using Elasticsearch, hybrid KNN + text search, and Reciprocal Rank Fusion
- **`computations/`**: live-coding exercises demonstrating the Vector API and SIMD operations

Please don't use what you see in `main` in production; this branch is the starting point for our talk. If you're intrigued by how this code can be modernised, find the talk on YouTube and leave a star :-)

## Prerequisites

- JDK 28
- Docker (for the image-text encoder)

## Running the tests

No manual setup needed: the integration tests spin up Elasticsearch and the encoder automatically via Testcontainers:

```bash
./mvnw verify
```

## Running the full demo

The search demo requires three things: the image-text encoder, an Elasticsearch instance with data, and the searcher itself.

### 1. Start the image-text encoder

Pull and run the pre-built Jina image (CPU, amd64):

```bash
docker pull ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu
docker run -d -p 8080:8080 ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu
```

The image is published for amd64 only. If you're on a different architecture (e.g. Apple Silicon), add `--platform linux/amd64` to both commands, and Docker will run it under emulation, which works fine for this demo:

```bash
docker pull --platform linux/amd64 ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu
docker run -d --platform linux/amd64 -p 8080:8080 ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu
```

See [`image-text-encoder/README.md`](./image-text-encoder/README.md) for details and API reference.

### 2. Start Elasticsearch and import the catalogue

Start an Elasticsearch instance, then set the environment variables and import the data:

```bash
export ES_URL=http://localhost:9200
export ES_API_KEY=<your_api_key>
cd searcher/src/test/resources && ./data_import.sh && cd -
```

Tip: copy `.env.example` to `.env`, fill in your values, and `source .env` (it's gitignored).

### 3. Run the searcher

```bash
./mvnw compile exec:exec -pl searcher
```

**From IntelliJ IDEA:** edit the run configuration for `EnterpriseySearcher`, add environment variables `ES_URL` and `ES_API_KEY`, set Language Level to "28 (Preview)", and click Run.

#### Environment variables

| Variable | Default | Description |
|---|---|---|
| `ES_URL` | (required) | Elasticsearch URL, e.g. `http://localhost:9200` |
| `ES_API_KEY` | (required) | Elasticsearch API key |
| `ENCODER_URL` | `http://localhost:8080/v1/embeddings` | Image-text encoder endpoint |

#### How it works

1. For each text query, the searcher asks the encoder for a vector representation
2. It runs a KNN vector search and a classic text search against the `catalogue` index in Elasticsearch
3. Results are merged with Reciprocal Rank Fusion (RRF) and printed with filename, price, and path

#### Example output

```
orange: [fruit-4637398_1280.jpg (4.00 BRL), apple-256261_1280.jpg (1.20 GBP), ...]
apple: [apple-256261_1280.jpg (1.20 GBP), apple-1868496_1280.jpg (12345.67 USD), ...]
Heckscheibenwaschanlage: [water-sprinkler-2804691_1280.jpg (10.00 EUR), ...]
jabłko: [apple-256261_1280.jpg (1.20 GBP), fruit-4637398_1280.jpg (4.00 BRL), ...]
```

The index structure is defined in [`searcher/src/test/resources/mapping.json`](./searcher/src/test/resources/mapping.json).

Thank you!
