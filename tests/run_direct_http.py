import os
import subprocess
import sys


server = subprocess.Popen(
    [sys.executable, "tests/direct_http_server.py"],
    stdout=subprocess.PIPE,
    text=True,
)
try:
    port = server.stdout.readline().strip()
    if not port:
        raise RuntimeError("Mock HTTP server failed to start")
    env = os.environ.copy()
    env["PAIR_TEST_HTTP_PORT"] = port
    for script in ("tests/direct_http.lua", "tests/direct_pair_flow.lua"):
        result = subprocess.run(
            ["nvim", "--headless", "-u", "NONE", "-l", script], env=env
        )
        if result.returncode:
            raise SystemExit(result.returncode)
finally:
    server.terminate()
    server.wait(timeout=5)
