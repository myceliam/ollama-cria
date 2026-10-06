"""Fixed TCP relays over Tailscale; no direct-internet fallback or URL fetching."""
import asyncio
import os

HOST = os.environ.get("VPS_HOST", "{{VPS_TS_IP}}")
PORTS = {8080: 18080, 3000: 13000, 3055: 13055, 13100: 13100}


async def relay(reader, writer, local_port, remote_port):
    upstream = None
    try:
        remote_reader, upstream = await asyncio.wait_for(
            asyncio.open_connection(HOST, remote_port), timeout=10
        )

        async def copy(source, target):
            while chunk := await source.read(65536):
                target.write(chunk)
                await target.drain()
            if target.can_write_eof():
                target.write_eof()

        await asyncio.wait_for(
            asyncio.gather(copy(reader, upstream), copy(remote_reader, writer)),
            timeout=300,
        )
    except (OSError, asyncio.TimeoutError) as exc:
        # Log only route metadata and the exception class/message. Never log
        # request bytes, queries, URLs or bodies, and never try a fallback.
        print(
            f"relay_error local={local_port} remote={HOST}:{remote_port} "
            f"type={type(exc).__name__} detail={str(exc)[:240]}",
            flush=True,
        )
    finally:
        writer.close()
        if upstream:
            upstream.close()


async def main():
    servers = []
    for local, remote in PORTS.items():
        server = await asyncio.start_server(
            lambda r, w, src=local, dst=remote: relay(r, w, src, dst), "0.0.0.0", local
        )
        servers.append(server)
        print(f"Listening {local} -> VPS:{remote}", flush=True)
    await asyncio.gather(*(server.serve_forever() for server in servers))


if __name__ == "__main__":
    asyncio.run(main())
