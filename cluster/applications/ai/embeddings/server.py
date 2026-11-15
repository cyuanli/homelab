import json, os, threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from fastembed import TextEmbedding

MODEL = os.environ.get("MODEL", "intfloat/multilingual-e5-large")
m = TextEmbedding(MODEL, cache_dir="/models", threads=int(os.environ.get("THREADS", "4")), local_files_only=True)
lock = threading.Lock()  # one ONNX run at a time; parallel runs would just fight over the cores


class H(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/health" else 404)
        self.end_headers()

    def do_POST(self):
        if self.path != "/embed":
            self.send_response(404); self.end_headers(); return
        try:
            inputs = json.loads(self.rfile.read(int(self.headers["Content-Length"])))["inputs"]
            if isinstance(inputs, str):
                inputs = [inputs]
            with lock:
                out = [e.tolist() for e in m.embed(inputs)]
        except Exception as e:
            body = json.dumps({"error": str(e)}).encode()
            self.send_response(400)
        else:
            body = json.dumps(out).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


print(f"serving {MODEL} on :8080", flush=True)
ThreadingHTTPServer(("", 8080), H).serve_forever()
