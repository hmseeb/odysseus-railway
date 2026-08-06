# odysseus-railway

Container images behind the [Odysseus (w/ Search + RAG)](https://railway.com/deploy/odysseus-w-search-rag)
Railway template. Nothing here is meant to be run by hand; the template wires
it all up for you.

[Odysseus](https://github.com/odysseus-dev/odysseus) is a self-hosted AI
workspace: chat, agents, deep research, documents, email, notes, tasks and
calendar. It is AGPL-3.0-or-later.

## What gets built

| Image | What it is |
|---|---|
| `ghcr.io/hmseeb/odysseus-railway` | Odysseus itself, pinned to a commit on the curated `main` branch, trimmed for Railway |
| `ghcr.io/hmseeb/odysseus-railway-searxng` | SearXNG with its JSON API switched on |

## Why these exist rather than the upstream images

**Odysseus.** Upstream builds an image but leaves the package private, so it
cannot be pulled anonymously and a Railway template cannot use it. Rebuilding it
also lets the image shed everything that cannot function on a hosting platform:
the compiler toolchain used to build llama.cpp, Chromium and Node for the
browser tool, tmux and ssh for background jobs on remote GPU boxes, a Docker
client for controlling the host daemon, and the Real-ESRGAN wheels for GPU image
upscaling. Roughly 3 GB comes off and no feature a Railway deployer could
actually reach is lost.

Two changes are additive rather than subtractive:

- The server binds one genuinely dual-stack socket. Railway dials containers
  over IPv6 while its health checker speaks IPv4, and Python's asyncio makes an
  IPv6 socket v6-only by default, so `uvicorn --host ::` is not enough. See
  `railway_serve.py`.
- The embedding model cache is redirected onto the one directory Railway
  persists, so it is not re-downloaded on every deploy.

**SearXNG.** Odysseus talks to SearXNG only over its JSON API, which is off in
SearXNG's default settings. Upstream turns it on with a bind-mounted settings
file. Railway cannot mount files into a service, so the same settings are baked
into an image instead.

## Contract tests

Both images are gated on a test before anything is published:

```bash
docker build -f Dockerfile.odysseus -t odysseus-railway:test .
./test/odysseus_test.sh odysseus-railway:test

docker build -f Dockerfile.searxng -t odysseus-railway-searxng:test .
./test/searxng_test.sh odysseus-railway-searxng:test
```

They assert the things that break silently: that the trimmed dependency set
still boots, that the listener answers on both IPv4 and IPv6, that the admin
account seeds from an environment variable rather than a terminal prompt, that
state lands on the persisted path, and that SearXNG really returns JSON.

## Updating

The upstream commit is the `ODYSSEUS_REF` build argument in
`Dockerfile.odysseus`; the SearXNG version is the base image tag in
`Dockerfile.searxng`. Both are bumped by hand. Pushing to `main` rebuilds and
republishes.
