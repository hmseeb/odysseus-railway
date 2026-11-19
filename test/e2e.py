#!/usr/bin/env python3
"""End-to-end check of a deployed Odysseus template: login, web search through
SearXNG, a document into RAG (ChromaDB), and one real LLM turn that has to
answer from that document.

Usage: ODY_URL=https://... ODY_USER=admin ODY_PASS=... ANTHROPIC_API_KEY=... \
       python3 -I test/e2e.py [model]

The key is only sent to the deployment under test. Nothing is printed from it.
"""
import http.cookiejar
import json
import os
import sys
import time
import urllib.parse
import urllib.request
import uuid

BASE = os.environ["ODY_URL"].rstrip("/")
MODEL = sys.argv[1] if len(sys.argv) > 1 else "claude-haiku-5-5"
CODEWORD = "PURPLE-OTTER-" + uuid.uuid4().hex[:6].upper()

jar = http.cookiejar.CookieJar()
op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
FAILED = []


def call(method, path, data=None, form=None, files=None, timeout=180):
    headers = {"Origin": BASE, "Accept": "application/json"}
    body = None
    if data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    elif files is not None:
        b = uuid.uuid4().hex
        parts = []
        for k, v in (form or {}).items():
            parts.append(f'--{b}\r\nContent-Disposition: form-data; name="{k}"\r\n\r\n{v}\r\n'.encode())
        for name, content in files:
            parts.append(f'--{b}\r\nContent-Disposition: form-data; name="files"; filename="{name}"\r\n'
                         f'Content-Type: text/plain\r\n\r\n'.encode() + content + b"\r\n")
        body = b"".join(parts) + f"--{b}--\r\n".encode()
        headers["Content-Type"] = f"multipart/form-data; boundary={b}"
    elif form is not None:
        body = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(BASE + path, data=body, method=method, headers=headers)
    try:
        with op.open(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw[:1] in (b"{", b"[") else raw.decode(errors="replace"))
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:400]


def check(name, ok, detail=""):
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok else f"\n        {str(detail)[:400]}"))
    if not ok:
        FAILED.append(name)


s, r = call("GET", "/api/health")
check("health", s == 200, r)

s, r = call("POST", "/api/auth/login", {"username": os.environ.get("ODY_USER", "admin"), "password": os.environ["ODY_PASS"]})
check("login", s == 200 and (not isinstance(r, dict) or r.get("ok", True) is not False), r)

s, r = call("POST", "/api/search/query", {"query": "python programming language", "provider": "searxng", "count": 5})
n = len(r.get("results") or []) if isinstance(r, dict) else 0
check(f"web search via searxng ({n} results)", s == 200 and n > 0, r)

doc = f"Internal memo. The secret project codeword is {CODEWORD}. Keep it private.\n".encode()
s, r = call("POST", "/api/personal/upload", files=[(f"memo-{CODEWORD.lower()}.txt", doc)], timeout=600)
check("RAG upload indexed", s == 200 and isinstance(r, dict) and (r.get("indexed_count") or 0) > 0, r)

s, r = call("GET", "/api/rag/stats")
check("RAG stats", s == 200, r)
print("        rag stats:", json.dumps(r)[:200])

key = os.environ.get("ANTHROPIC_API_KEY", "")
if not key:
    check("LLM turn", False, "ANTHROPIC_API_KEY not set")
else:
    s, ep = call("POST", "/api/model-endpoints", form={
        "name": "anthropic-e2e", "base_url": "https://api.anthropic.com/v1", "api_key": key,
        "pinned_models": MODEL, "model_type": "llm"})
    check("add anthropic endpoint", s == 200 and isinstance(ep, dict), ep)
    eid = (ep.get("id") or (ep.get("endpoint") or {}).get("id") or "") if isinstance(ep, dict) else ""
    s, sess = call("POST", "/api/session", form={"name": "e2e", "endpoint_id": eid, "model": MODEL, "rag": "true",
                                                    # upstream validates Anthropic models against a static
                                                    # catalog that lags new releases (src/llm_core.py)
                                                    "skip_validation": "true"})
    check("create session", s == 200 and isinstance(sess, dict), sess)
    sid = (sess.get("id") or sess.get("session_id") or "") if isinstance(sess, dict) else ""
    t = time.time()
    s, r = call("POST", "/api/chat", {"message": "What is the secret project codeword in my documents? Reply with only the codeword.",
                                       "session": sid, "selected_endpoint_id": eid}, timeout=300)
    text = json.dumps(r) if not isinstance(r, str) else r
    check(f"LLM turn answers from RAG ({time.time()-t:.0f}s)", s == 200 and CODEWORD in text, text)
    print("        reply:", (r.get("response") if isinstance(r, dict) else text)[:160] if r else "")

print("\nPASS" if not FAILED else f"\nFAILED: {FAILED}")
sys.exit(1 if FAILED else 0)
