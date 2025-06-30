# serve_with_threads.py
import http.server
import socketserver

class ThreadSafeHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()

PORT = 8000
with socketserver.TCPServer(("", PORT), ThreadSafeHandler) as httpd:
    print(f"Serving with thread-safe headers at http://localhost:{PORT}")
    httpd.serve_forever()
