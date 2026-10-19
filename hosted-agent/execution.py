"""Bounded command execution for a trusted-user lab, not a security sandbox."""

import io
import os
import selectors
import shlex
import signal
import subprocess
import time

OUTPUT_LIMIT = 16384


def validate_command(command: str, target: str, timeout_seconds: int) -> None:
    if not command.strip() or "\0" in command or len(command) > 8192:
        raise ValueError("Command must contain 1-8192 characters and no NUL.")
    if target not in ("sandbox", "jump"):
        raise ValueError("Target must be sandbox or jump.")
    if not 1 <= timeout_seconds <= 60:
        raise ValueError("Timeout must be between 1 and 60 seconds.")


def result(output: bytearray, status: str, exit_code: int | None) -> dict:
    return {
        "status": status,
        "exit_code": exit_code,
        "output": bytes(output).decode("utf-8", errors="replace"),
        "truncated": status == "output_limit",
    }


def run_local(command: str, timeout_seconds: int) -> dict:
    validate_command(command, "sandbox", timeout_seconds)
    output = bytearray()
    status = "completed"
    deadline = time.monotonic() + timeout_seconds
    with subprocess.Popen(
        ["/bin/sh", "-c", command],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    ) as process, selectors.DefaultSelector() as selector:
        assert process.stdout is not None
        selector.register(process.stdout, selectors.EVENT_READ)
        try:
            while selector.get_map() or process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    status = "timeout"
                    break
                if not selector.get_map():
                    time.sleep(min(0.05, remaining))
                    continue
                for key, _ in selector.select(min(0.1, remaining)):
                    chunk = os.read(key.fd, min(4096, OUTPUT_LIMIT - len(output) + 1))
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    available = OUTPUT_LIMIT - len(output)
                    output.extend(chunk[:available])
                    if len(chunk) > available:
                        status = "output_limit"
                        break
                if status != "completed":
                    break
        finally:
            # Also stop ordinary descendants when their parent exits first.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return result(output, status, process.returncode)


def run_remote(command: str, timeout_seconds: int) -> dict:
    import paramiko
    from azure.identity import DefaultAzureCredential
    from azure.keyvault.secrets import SecretClient

    validate_command(command, "jump", timeout_seconds)
    host, port = os.environ["SSH_HOST"], int(os.environ["SSH_PORT"])
    entry = paramiko.hostkeys.HostKeyEntry.from_line(os.environ["SSH_KNOWN_HOST"])
    if entry is None or entry.key is None:
        raise ValueError("SSH_KNOWN_HOST must contain a pinned OpenSSH host-key entry.")
    with DefaultAzureCredential() as credential, SecretClient(
        vault_url=os.environ["SSH_VAULT_URL"], credential=credential,
        connection_timeout=10, read_timeout=10, retry_total=0,
    ) as secrets:
        value = secrets.get_secret(os.environ["SSH_SECRET_NAME"]).value
    if not value:
        raise ValueError("The SSH secret is empty.")
    private_key = paramiko.Ed25519Key.from_private_key(io.StringIO(value))
    del value
    output = bytearray()
    with paramiko.SSHClient() as client:
        for name in entry.hostnames:
            client.get_host_keys().add(name, entry.key.get_name(), entry.key)
        client.connect(
            host, port=port, username=os.environ["SSH_USER"], pkey=private_key,
            allow_agent=False, look_for_keys=False, timeout=10,
            banner_timeout=10, auth_timeout=10, channel_timeout=10,
        )
        # The server-side timeout still applies if the client disconnects.
        wrapped = f"timeout --signal=TERM --kill-after=2s {timeout_seconds}s /bin/sh -c {shlex.quote(command)}"
        transport = client.get_transport()
        if transport is None:
            raise RuntimeError("SSH transport was not established.")
        with transport.open_session(timeout=10) as channel:
            channel.set_combine_stderr(True)
            channel.settimeout(10)
            channel.exec_command(wrapped)
            channel.shutdown_write()
            deadline = time.monotonic() + timeout_seconds + 3
            status = "completed"
            while True:
                if time.monotonic() >= deadline:
                    status = "timeout"
                    break
                if channel.recv_ready():
                    chunk = channel.recv(min(4096, OUTPUT_LIMIT - len(output) + 1))
                    available = OUTPUT_LIMIT - len(output)
                    output.extend(chunk[:available])
                    if len(chunk) > available:
                        status = "output_limit"
                        break
                elif channel.exit_status_ready():
                    break
                else:
                    time.sleep(0.02)
            code = channel.recv_exit_status() if status == "completed" else None
            if code in (124, 137):
                status = "timeout"
            return result(output, status, code)
