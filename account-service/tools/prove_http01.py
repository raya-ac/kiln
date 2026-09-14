"""Approved, scoped HTTP-01 proof. Creates and always removes one random token."""
from pathlib import PurePosixPath
import secrets
import subprocess

host = "root@46.250.246.198"
name = "kiln-proof-" + secrets.token_hex(16)
path = str(PurePosixPath("/opt/layerline/public/.well-known/acme-challenge") / name)
content = secrets.token_urlsafe(32)
ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "StrictHostKeyChecking=yes",
       "-o", "UpdateHostKeys=no", host, "python3", "-"]
created = False
try:
    code = f"import os\np={path!r}\nf=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o644)\nos.write(f,{content.encode()!r})\nos.close(f)\n"
    subprocess.run(ssh, input=code, text=True, check=True, timeout=15)
    created = True
    response = subprocess.run(["curl", "--silent", "--show-error", "--fail-with-body", "--max-time", "15",
                               "http://kiln.raya.ac/.well-known/acme-challenge/" + name],
                              capture_output=True, timeout=20)
    if response.returncode or response.stdout != content.encode():
        print(response.stderr.decode()[:300])
        print(response.stdout.decode(errors="replace")[:300])
        raise RuntimeError("HTTP-01 public proof did not match")
    print("HTTP-01 public body match: PASS")
finally:
    if created:
        code = f"import os\np={path!r}\nos.unlink(p)\nassert not os.path.exists(p)\n"
        subprocess.run(ssh, input=code, text=True, check=True, timeout=15)
        print("HTTP-01 proof file removed: PASS")
