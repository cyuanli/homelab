# Embeddings

Keeps `intfloat/multilingual-e5-large` (fastembed's ONNX export `Qdrant/multilingual-e5-large-onnx`)
loaded on `cyl-aspiree17` so Hermes's `semindex.py` doesn't load 2.1GB into its own pod for every
search and update. Same fastembed/onnxruntime versions as Hermes's venv, so vectors match the
existing index (checked: cosine 1.000000 against stored chunks). Bump them together with Hermes's.

In-cluster only: `http://embeddings.ai.svc:8080`, no auth.

```bash
# POST /embed {"inputs": [str, ...] | str} -> [[float x1024], ...]; GET /health
curl -s embeddings.ai.svc:8080/embed -H 'Content-Type: application/json' -d '{"inputs":["query: hello"]}'
```

e5 needs the `query: ` / `passage: ` prefix on each input; the server doesn't add it.

One query takes ~0.15s. Bulk is slow on this 2-core i7-6500U: ~2.6s per long chunk (16 in 42s),
fine for the hourly incremental update but a full re-index takes hours. Requests are serialized.
Peak ~2.3Gi.

## Model files

`/srv/app-storage/embeddings` on `cyl-aspiree17` (hostPath, not backed up). The container runs
offline (`HF_HUB_OFFLINE=1`) and waits for `/models/.ready`. To (re)fill it, copy Hermes's cache:

```bash
kubectl -n ai exec deploy/hermes -c hermes -- tar -C /opt/data/index/models -cf - --exclude=.locks . \
  | kubectl -n ai exec -i deploy/embeddings -c embeddings -- tar -C /models -xf -
kubectl -n ai exec deploy/embeddings -c embeddings -- touch /models/.ready
```

`pip install` runs at every start.
