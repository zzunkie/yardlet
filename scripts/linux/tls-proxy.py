#!/usr/bin/env python3
"""Ends TLS on 127.0.0.1:PORT with CERT and KEY and passes each connection's bytes on to 127.0.0.1:TARGET, so the
local relay (wrangler dev, plain HTTP) can be reached as wss:// in the Linux host's checks.

    tls-proxy.py CERT KEY PORT TARGET
"""
import asyncio
import ssl
import sys

cert, key, port, target = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
context.load_cert_chain(cert, key)


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, ssl.SSLError):
        pass
    finally:
        writer.close()


async def handle(reader, writer):
    try:
        upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", target)
    except OSError:
        writer.close()
        return
    await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))


async def main():
    server = await asyncio.start_server(handle, "127.0.0.1", port, ssl=context)
    async with server:
        await server.serve_forever()


asyncio.run(main())
