"""Serve Odysseus on one socket that answers over both IPv4 and IPv6.

Railway's private network is IPv6 and the platform dials containers over it,
while Railway's own health checker still speaks IPv4. An app has to answer on
both or it fails one of the two, and the symptom is identical either way: the
container logs look perfectly healthy while every deploy reports "service
unavailable".

`uvicorn --host 0.0.0.0` covers only v4. `uvicorn --host ::` looks like the fix
but is not, because asyncio sets IPV6_V6ONLY on every AF_INET6 server socket it
creates, which locks out v4-mapped addresses. The only way to get one
genuinely dual-stack listener is to build the socket here, clear that flag
before binding, and hand the descriptor to uvicorn.
"""

import os
import socket

import uvicorn

PORT = int(os.environ.get("PORT") or 7000)

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
sock.bind(("::", PORT))
sock.listen(2048)

if __name__ == "__main__":
    uvicorn.run("app:app", fd=sock.fileno())
