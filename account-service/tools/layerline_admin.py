"""Send one explicit command to the existing local Layerline management socket."""
import argparse
import socket

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=["status", "validate", "validate-runtime", "diff", "reload"])
args = parser.parse_args()
with socket.socket(socket.AF_UNIX) as stream:
    stream.settimeout(10)
    stream.connect("/run/layerline-admin.sock")
    stream.sendall((args.command + "\n").encode())
    stream.shutdown(socket.SHUT_WR)
    chunks = []
    size = 0
    while True:
        chunk = stream.recv(8192)
        if not chunk:
            break
        size += len(chunk)
        if size > 65536:
            raise RuntimeError("oversized management response")
        chunks.append(chunk)
    result = b"".join(chunks).decode()
print(result, end="")
if args.command in ("validate", "validate-runtime", "reload") and not result.startswith("OK "):
    raise SystemExit(1)
