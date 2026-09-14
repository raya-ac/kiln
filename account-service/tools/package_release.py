"""Generate a deterministic source manifest and transfer archive in .cache."""
import hashlib
import json
import os
from pathlib import Path
import tarfile

root = Path(__file__).resolve().parents[1]
excluded = {".cache", ".test-tmp", ".test-pg", ".venv", "__pycache__", "wheelhouse"}
files = []
for directory, names, filenames in os.walk(root):
    names[:] = [name for name in names if name not in excluded]
    for name in filenames:
        path = Path(directory) / name
        if path.is_file() and not path.is_symlink() and not any(s in name for s in (".sqlite3", ".pyc", ".dump")):
            files.append(path)
files.sort()
manifest = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
encoded = json.dumps(manifest, sort_keys=True, indent=2).encode() + b"\n"
release = "20260914-account-pg-v1-" + hashlib.sha256(encoded).hexdigest()[:12]
cache = root / ".cache"
cache.mkdir(exist_ok=True)
manifest_path = cache / (release + ".manifest.json")
manifest_path.write_bytes(encoded)
archive = cache / (release + ".tar.gz")
with tarfile.open(archive, "w:gz") as tar:
    for path in files:
        tar.add(path, arcname=path.relative_to(root), recursive=False)
    tar.add(manifest_path, arcname="SOURCE_MANIFEST.json", recursive=False)
print(json.dumps({"release": release, "archive": str(archive), "archiveSha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "files": len(files)}))
