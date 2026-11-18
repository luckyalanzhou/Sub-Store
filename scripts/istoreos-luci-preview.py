#!/usr/bin/env python3
"""Run a disposable iStoreOS QEMU guest for local LuCI acceptance."""

from __future__ import annotations

import argparse
import http.client
import importlib.util
import os
import pathlib
import pexpect
import signal
import shutil
import socket
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit


REPO = pathlib.Path(__file__).resolve().parents[1]
TEST_SCRIPT = REPO / "tests" / "istoreos-qemu.py"
DEFAULT_PACKAGE = REPO / "dist" / "sub-store-0.0.29.run"
DEFAULT_RELEASE = "25.12.5-2026092410"
STATE_ROOT = pathlib.Path.home() / ".local" / "state" / "sub-store-istoreos-preview"
HTTP_PORT = 18765
SSH_PORT = 2222
LUCI_PORT = 18081
ROOT_PASSWORD = "test"
HOST_ADDRESS = "192.168.100.2"
GUEST_ADDRESS = "192.168.100.15"
DATA_DISK_SIZE_GIB = 8


def load_test_helpers():
    spec = importlib.util.spec_from_file_location("istoreos_qemu_test", TEST_SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load QEMU helpers from {TEST_SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TEST = load_test_helpers()


def require_tools() -> None:
    missing = [name for name in ("qemu-system-x86_64", "mkfs.ext4", "ssh", "ssh-keygen")
               if shutil.which(name) is None]
    if missing:
        raise RuntimeError("Missing WSL tools: " + ", ".join(missing))


def process_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def process_start_ticks(pid: int) -> int | None:
    try:
        stat = pathlib.Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
        return int(stat.rsplit(")", 1)[1].split()[19])
    except (IndexError, OSError, ValueError):
        return None


def read_process_identity() -> tuple[int, int] | None:
    path = STATE_ROOT / "active.pid"
    try:
        values = path.read_text(encoding="ascii").split()
        if len(values) != 2:
            return None
        pid, start_ticks = (int(value) for value in values)
    except (OSError, ValueError):
        return None
    if pid <= 1 or start_ticks < 0 or process_start_ticks(pid) != start_ticks:
        return None
    return pid, start_ticks


def read_pid() -> int | None:
    identity = read_process_identity()
    return identity[0] if identity is not None else None


def process_identity_alive(identity: tuple[int, int]) -> bool:
    pid, start_ticks = identity
    return process_start_ticks(pid) == start_ticks and process_alive(pid)


def signal_preview_process(identity: tuple[int, int], signal_number: int) -> bool:
    pid, start_ticks = identity
    pidfd_open = getattr(os, "pidfd_open", None)
    pidfd_send_signal = getattr(signal, "pidfd_send_signal", None)
    if pidfd_open is None or pidfd_send_signal is None:
        return False
    try:
        pidfd = pidfd_open(pid, 0)
    except OSError:
        return False
    try:
        if process_start_ticks(pid) != start_ticks:
            return False
        pidfd_send_signal(pidfd, signal_number)
        return True
    except OSError:
        return False
    finally:
        os.close(pidfd)


def tail_log(path: pathlib.Path, lines: int = 35) -> str:
    try:
        return "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[-lines:])
    except OSError:
        return ""


def start(args: argparse.Namespace) -> int:
    pid = read_pid()
    if pid is not None and process_alive(pid):
        print(f"Preview already running (PID {pid}).")
        print(f"URL: http://127.0.0.1:{LUCI_PORT}/cgi-bin/luci/admin/services/sub-store")
        return 0

    # Keep the WSL command attached to the VM. WSL may stop a distro after its
    # launcher exits, which would also terminate a detached QEMU child.
    print(f"Starting iStoreOS {args.release} QEMU preview. Press Ctrl+C to stop.", flush=True)
    return serve(argparse.Namespace(release=args.release, package=args.package))


def start_package_server(package: pathlib.Path) -> ThreadingHTTPServer:
    class PackageRequestHandler(BaseHTTPRequestHandler):
        def log_message(self, _format: str, *_args) -> None:
            pass

        def do_GET(self):
            request_path = unquote(urlsplit(self.path).path)
            if request_path != f"/{package.name}":
                self.send_error(404)
                return
            try:
                package_stat = package.stat()
                with package.open("rb") as source:
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(package_stat.st_size))
                    self.end_headers()
                    shutil.copyfileobj(source, self.wfile)
            except OSError:
                self.send_error(404)

        def do_HEAD(self):
            request_path = unquote(urlsplit(self.path).path)
            if request_path != f"/{package.name}":
                self.send_error(404)
                return
            try:
                package_stat = package.stat()
            except OSError:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(package_stat.st_size))
            self.end_headers()

    server = ThreadingHTTPServer(("127.0.0.1", HTTP_PORT), PackageRequestHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    server.preview_thread = thread
    return server


def qemu_network_config() -> str:
    return (
        f"user,id=lan,net=192.168.100.0/24,host={HOST_ADDRESS},dns=192.168.100.3,"
        f"hostfwd=tcp:127.0.0.1:{SSH_PORT}-{GUEST_ADDRESS}:22,"
        f"hostfwd=tcp:127.0.0.1:{LUCI_PORT}-{GUEST_ADDRESS}:80,"
        f"guestfwd=tcp:{HOST_ADDRESS}:{HTTP_PORT}-tcp:127.0.0.1:{HTTP_PORT}"
    )


def wait_for_luci(timeout: int = 120) -> int:
    deadline = time.monotonic() + timeout
    last_error = "no response"
    while time.monotonic() < deadline:
        connection = http.client.HTTPConnection("127.0.0.1", LUCI_PORT, timeout=5)
        try:
            connection.request("GET", "/cgi-bin/luci/admin/services/sub-store")
            response = connection.getresponse()
            response.read(1024)
            if response.status == 200 or (
                response.status == 403 and
                response.getheader("x-luci-login-required", "").lower() == "yes"
            ):
                return response.status
            last_error = f"HTTP {response.status}"
        except OSError as error:
            last_error = str(error)
        finally:
            connection.close()
        time.sleep(2)
    raise TimeoutError(f"LuCI did not respond on localhost:{LUCI_PORT}: {last_error}")


def serve(args: argparse.Namespace) -> int:
    require_tools()
    package = pathlib.Path(args.package).resolve()
    if not package.is_file():
        raise RuntimeError(f"Installer not found: {package}")
    firmware = TEST.FIRMWARES.get(args.release)
    if firmware is None:
        raise RuntimeError(f"Unsupported iStoreOS release: {args.release}")
    image_name, sha256, _package_manager = firmware

    release_dir = STATE_ROOT / args.release
    release_dir.mkdir(parents=True, exist_ok=True)
    pid = os.getpid()
    start_ticks = process_start_ticks(pid)
    if start_ticks is None:
        raise RuntimeError("Cannot verify the preview process identity through /proc.")
    (STATE_ROOT / "active.pid").write_text(f"{pid} {start_ticks}\n", encoding="ascii")
    (STATE_ROOT / "active.release").write_text(args.release, encoding="ascii")
    ready_path = release_dir / "ready"
    disk_path = release_dir / "istoreos.img"
    docker_disk_path = release_dir / "docker-data.img"
    key_path = release_dir / "id_ed25519"
    qemu_log_path = release_dir / "serial.log"

    for port in (SSH_PORT, LUCI_PORT, HTTP_PORT):
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError as error:
                raise RuntimeError(f"Local port {port} is already in use: {error}") from error

    if not disk_path.is_file():
        TEST.download_firmware(release_dir, image_name, sha256)
    if not docker_disk_path.is_file():
        with docker_disk_path.open("wb") as disk:
            disk.truncate(DATA_DISK_SIZE_GIB * 1024 * 1024 * 1024)
        subprocess.run(["mkfs.ext4", "-F", "-m", "0", str(docker_disk_path)], check=True)
    if not key_path.is_file():
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key_path)], check=True)
    public_key = key_path.with_suffix(".pub").read_bytes()

    qemu_log = qemu_log_path.open("w", encoding="utf-8")
    qemu_args = [
        "-machine", "pc,accel=tcg",
        "-m", "2048",
        "-smp", "2",
        "-drive", f"file={disk_path},format=raw,if=virtio",
        "-drive", f"file={docker_disk_path},format=raw,if=virtio",
        "-netdev",
        qemu_network_config(),
        "-device", "virtio-net-pci,netdev=lan",
        "-display", "none",
        "-monitor", "none",
        "-serial", "stdio",
    ]
    qemu = pexpect.spawn("qemu-system-x86_64", qemu_args, encoding="utf-8",
                         codec_errors="replace", timeout=30)
    qemu.logfile_read = qemu_log
    httpd = None
    stop_event = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop_event.set())
    signal.signal(signal.SIGINT, lambda *_: stop_event.set())

    try:
        print(f"Booting iStoreOS {args.release}.", flush=True)
        TEST.provision_guest(qemu, public_key)
        TEST.wait_for_ssh(SSH_PORT, key_path)
        TEST.ssh_command(
            SSH_PORT,
            key_path,
            "set -e; mkdir -p /opt/docker; mount -t ext4 /dev/vdb /opt/docker; "
            "/etc/init.d/dockerd start; "
            "for attempt in $(seq 1 30); do docker info >/dev/null 2>&1 && exit 0; sleep 2; done; exit 1",
            timeout=120,
        )

        current_version = TEST.ssh_command(
            SSH_PORT, key_path,
            "if [ -r /etc/sub-store/version ]; then cat /etc/sub-store/version; else echo absent; fi",
            show_output=False,
        )
        package_version = package.name.removeprefix("sub-store-").removesuffix(".run")
        if current_version != package_version:
            remote_package = f"/tmp/{package.name}"
            httpd = start_package_server(package)
            try:
                TEST.ssh_command(
                    SSH_PORT, key_path,
                    f"wget -q -O '{remote_package}' http://{HOST_ADDRESS}:{HTTP_PORT}/{package.name}",
                    timeout=300,
                    show_output=False,
                )
            finally:
                httpd.shutdown()
                httpd.server_close()
                httpd.preview_thread.join(timeout=2)
                httpd = None
            install_prefix = "" if current_version == "absent" else "SUB_STORE_PLUGIN_ONLY=1 "
            TEST.ssh_command(
                SSH_PORT, key_path,
                f"chmod 700 '{remote_package}' && {install_prefix}'{remote_package}'",
                timeout=TEST.INSTALL_TIMEOUT_SECONDS,
                show_output=False,
            )
        TEST.wait_for_ssh(SSH_PORT, key_path)
        container_state = TEST.ssh_command(
            SSH_PORT, key_path, "/usr/bin/sub-storectl status", show_output=False
        )
        TEST.serial_command(
            qemu, f"printf '%s\\n' 'root:{ROOT_PASSWORD}' | chpasswd"
        )
        TEST.serial_command(
            qemu,
            f"test \"$(cat /etc/sub-store/version)\" = '{package_version}' && "
            "test -x /usr/bin/sub-storectl && /usr/bin/sub-storectl status >/dev/null",
        )
        http_status = wait_for_luci()
        print(f"Plugin version: {package_version}; container state: {container_state}", flush=True)
        print(f"LuCI: http://127.0.0.1:{LUCI_PORT}/cgi-bin/luci/admin/services/sub-store", flush=True)
        print(f"Login: root / {ROOT_PASSWORD}", flush=True)
        print(f"LuCI HTTP response: {http_status}", flush=True)
        print("Docker runs inside this isolated iStoreOS guest; the Windows Docker engine stays empty.", flush=True)
        ready_path.write_text("ready\n", encoding="ascii")

        while not stop_event.wait(1):
            if not qemu.isalive():
                raise RuntimeError("QEMU exited unexpectedly.")
    finally:
        ready_path.unlink(missing_ok=True)
        if qemu.isalive():
            try:
                TEST.ssh_command(SSH_PORT, key_path, "poweroff", timeout=20, show_output=False)
            except Exception:
                pass
            deadline = time.monotonic() + 15
            while qemu.isalive() and time.monotonic() < deadline:
                time.sleep(0.5)
            qemu.terminate(force=True)
        qemu_log.close()
        if httpd is not None:
            httpd.shutdown()
            httpd.server_close()
            httpd.preview_thread.join(timeout=2)
        if read_pid() == os.getpid():
            (STATE_ROOT / "active.pid").unlink(missing_ok=True)
            (STATE_ROOT / "active.release").unlink(missing_ok=True)

    return 0


def status(_args: argparse.Namespace) -> int:
    pid = read_pid()
    release_path = STATE_ROOT / "active.release"
    release = release_path.read_text(encoding="ascii").strip() if release_path.exists() else "unknown"
    if pid is None or not process_alive(pid):
        print("STOPPED")
        return 0
    release_dir = STATE_ROOT / release
    if (release_dir / "ready").is_file():
        print(f"RUNNING iStoreOS {release} (PID {pid})")
        print(f"http://127.0.0.1:{LUCI_PORT}/cgi-bin/luci/admin/services/sub-store")
        print(f"Login: root / {ROOT_PASSWORD}")
    else:
        print(f"STARTING iStoreOS {release} (PID {pid})")
        print(tail_log(release_dir / "serial.log"))
    return 0


def stop(_args: argparse.Namespace) -> int:
    identity = read_process_identity()
    if identity is None or not process_alive(identity[0]):
        print("Preview is already stopped.")
        return 0
    pid = identity[0]
    if not signal_preview_process(identity, signal.SIGTERM):
        print("Could not safely signal the preview process; stop it from its foreground terminal.")
        return 1
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline and process_identity_alive(identity):
        time.sleep(0.5)
    if process_identity_alive(identity):
        if not signal_preview_process(identity, signal.SIGKILL):
            print("Could not safely force-stop the preview process; use its foreground terminal.")
            return 1
        print(f"Stopped preview process {pid} forcefully.")
    else:
        print("Stopped QEMU preview.")
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    start_parser = subparsers.add_parser("start", help="start the local iStoreOS VM")
    start_parser.add_argument("--release", choices=sorted(TEST.FIRMWARES), default=DEFAULT_RELEASE)
    start_parser.add_argument("--package", default=str(DEFAULT_PACKAGE))
    start_parser.set_defaults(func=start)
    serve_parser = subparsers.add_parser("serve", help=argparse.SUPPRESS)
    serve_parser.add_argument("--release", choices=sorted(TEST.FIRMWARES), required=True)
    serve_parser.add_argument("--package", required=True)
    serve_parser.set_defaults(func=serve)
    status_parser = subparsers.add_parser("status", help="show VM state")
    status_parser.set_defaults(func=status)
    stop_parser = subparsers.add_parser("stop", help="stop the local iStoreOS VM")
    stop_parser.set_defaults(func=stop)
    return parser.parse_args()


if __name__ == "__main__":
    try:
        arguments = parse_args()
        sys.exit(arguments.func(arguments))
    except Exception as error:
        print(f"iStoreOS LuCI preview failed: {error}", file=sys.stderr, flush=True)
        sys.exit(1)
