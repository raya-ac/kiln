"""Only loopback is supported. Layerline terminates HTTPS."""
import os

bind = os.environ.get("KILN_BIND", "127.0.0.1:27480")
if not bind.startswith("127.0.0.1:"):
    raise RuntimeError("account service must bind to IPv4 loopback")
workers = 2
worker_class = "sync"
threads = 1
timeout = 30
graceful_timeout = 30
max_requests = 2000
max_requests_jitter = 200
limit_request_line = 1024
limit_request_fields = 30
limit_request_field_size = 4096
forwarded_allow_ips = ""
accesslog = None
errorlog = "-"
capture_output = False
umask = 0o077
