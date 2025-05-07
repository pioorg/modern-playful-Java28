# Image-Text Encoder

This demo uses [Jina on-prem](https://github.com/jina-ai/jina-on-prem) to serve `jina-embeddings-v5-omni` multimodal embeddings locally via an OpenAI-compatible API on port 8080.

## Running the encoder

**GPU (recommended for speed):**
```bash
docker pull ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:gpu
docker run -d -p 8080:8080 --gpus all ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:gpu
```

**CPU on amd64:**
```bash
docker pull ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu
docker run -d -p 8080:8080 ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu
```

**CPU on arm64 (e.g. Apple Silicon):**

The published `:cpu` image is amd64-only. It works on arm64 just fine. However, it might be suoptimal in terms of performance. For native arm64 performance, build locally from [pioorg/jina-on-prem](https://github.com/pioorg/jina-on-prem):

```bash
git clone https://github.com/pioorg/jina-on-prem
cd jina-on-prem
python jina-on-prem.py bundle --model jina-embeddings-v5-omni-nano --cpu-only --yes
docker load < jina-embeddings-v5-omni-nano-cpu.tar.gz
docker tag jina/jina-embeddings-v5-omni-nano:cpu jina/jina-embeddings-v5-omni-nano:cpu-arm64
docker run -d -p 8080:8080 jina/jina-embeddings-v5-omni-nano:cpu-arm64
```

The image works fully **offline** once pulled - model weights are baked in and `HF_HUB_OFFLINE=1` is set.

To use the native arm64 image in the integration test instead of the amd64 `:cpu` image, change one line in `EnterpriseySearcherIntTest.java`:

```java
// replace this:
DockerImageName.parse("ghcr.io/jina-ai/jina-on-prem/jina-embeddings-v5-omni-nano:cpu")
// with the tag from the build command above:
DockerImageName.parse("jina/jina-embeddings-v5-omni-nano:cpu-arm64")
```

## Health check

```bash
curl http://localhost:8080/health
```

Returns `{"status":"ok","ready":true,...}` when the model is loaded.

## API

The encoder exposes an OpenAI-compatible embeddings endpoint at `POST /v1/embeddings`.

**Encode text (query):**
```bash
curl -X POST http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d '{"input": ["search query"], "task": "retrieval.query"}'
```

**Encode image (document):**
```bash
curl -X POST http://localhost:8080/v1/embeddings \
  -H "Content-Type: application/json" \
  -d "{\"input\": [{\"type\": \"image_url\", \"image_url\": {\"url\": \"data:image/jpeg;base64,$(base64 -i image.jpg | tr -d '\n')\"}}], \"task\": \"retrieval.passage\"}"
```

Response format:
```json
{"data": [{"embedding": [...], "index": 0}], "model": "...", "usage": {...}}
```

Set `ENCODER_URL` to override the default `http://localhost:8080/v1/embeddings` used by the scripts and `EnterpriseySearcher`.
