# SPDX-License-Identifier: MIT
"""A stand-in for Hackage's upload API, for tests/interactive.sh.

Usage: fake_hackage.py PORT_FILE UPLOAD_DIR

It listens on a free port of 127.0.0.1, writes the port to PORT_FILE, and
accepts what `cabal upload` sends: a package candidate (POST to
/packages/candidates/) and a documentation tarball (PUT to
/package/<id>/candidate/docs). Each request body goes to UPLOAD_DIR, in a
file named for the request, so the test can check that the uploaded bytes
are the files Nix built.
"""

import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

port_file, upload_dir = Path(sys.argv[1]), Path(sys.argv[2])
upload_dir.mkdir(parents=True, exist_ok=True)


class Handler(BaseHTTPRequestHandler):
    def receive(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        name = self.command + self.path.replace("/", "_")
        (upload_dir / name).write_bytes(body)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"accepted\n")

    do_POST = receive
    do_PUT = receive

    def log_message(self, format, *args):
        sys.stderr.write("fake-hackage: " + (format % args) + "\n")


server = HTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_address[1]))
server.serve_forever()
