import contextlib
import importlib.util
import io
import os
import pathlib
import socket
import sys
import tempfile
import threading
import types
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock
from urllib.error import HTTPError
from urllib.request import urlopen


ROOT = pathlib.Path(__file__).resolve().parents[1]
PREVIEW_PATH = ROOT / "scripts" / "istoreos-luci-preview.py"

# The preview runs under Linux/WSL and uses pexpect only when starting QEMU.
# Keep the management command tests runnable on Windows without that dependency.
try:
    import pexpect  # noqa: F401
except ImportError:
    sys.modules["pexpect"] = types.ModuleType("pexpect")

spec = importlib.util.spec_from_file_location("istoreos_luci_preview", PREVIEW_PATH)
PREVIEW = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = PREVIEW
spec.loader.exec_module(PREVIEW)


class LuCIHandler(BaseHTTPRequestHandler):
    status_code = 403
    login_header = "yes"

    def do_GET(self):
        self.send_response(self.status_code)
        if self.login_header:
            self.send_header("x-luci-login-required", self.login_header)
        self.end_headers()

    def log_message(self, _format, *_args):
        pass


class PreviewLauncherTests(unittest.TestCase):
    def test_read_pid_requires_matching_linux_start_time(self):
        start_ticks = PREVIEW.process_start_ticks(os.getpid())
        if start_ticks is None:
            self.skipTest("Linux /proc is unavailable")
        with tempfile.TemporaryDirectory() as temporary:
            state_root = pathlib.Path(temporary)
            (state_root / "active.pid").write_text(
                f"{os.getpid()} {start_ticks}\n", encoding="ascii"
            )
            with mock.patch.object(PREVIEW, "STATE_ROOT", state_root):
                self.assertEqual(PREVIEW.read_pid(), os.getpid())

    def test_starting_status_shows_qemu_serial_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_root = pathlib.Path(temporary)
            release_dir = state_root / "test-release"
            release_dir.mkdir()
            (state_root / "active.pid").write_text(f"{os.getpid()} 123\n", encoding="ascii")
            (state_root / "active.release").write_text("test-release", encoding="ascii")
            (release_dir / "serial.log").write_text("serial-diagnostic-marker\n", encoding="utf-8")
            output = io.StringIO()

            with mock.patch.object(PREVIEW, "STATE_ROOT", state_root), \
                    mock.patch.object(PREVIEW, "process_start_ticks", return_value=123), \
                    contextlib.redirect_stdout(output):
                PREVIEW.status(None)

            self.assertIn("STARTING iStoreOS", output.getvalue())
            self.assertIn("serial-diagnostic-marker", output.getvalue())

    def test_stop_ignores_reused_pid(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_root = pathlib.Path(temporary)
            (state_root / "active.pid").write_text(f"{os.getpid()} 123\n", encoding="ascii")

            with mock.patch.object(PREVIEW, "STATE_ROOT", state_root), \
                    mock.patch.object(PREVIEW, "process_start_ticks", return_value=456), \
                    mock.patch.object(PREVIEW.os, "kill") as kill, \
                    contextlib.redirect_stdout(io.StringIO()):
                PREVIEW.stop(None)

            kill.assert_not_called()

    def test_stop_uses_pidfd_and_rechecks_identity_before_signaling(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_root = pathlib.Path(temporary)
            (state_root / "active.pid").write_text(f"{os.getpid()} 123\n", encoding="ascii")
            output = io.StringIO()

            with mock.patch.object(PREVIEW, "STATE_ROOT", state_root), \
                    mock.patch.object(PREVIEW, "process_start_ticks", side_effect=[123, 456]), \
                    mock.patch.object(PREVIEW, "process_alive", return_value=True), \
                    mock.patch.object(PREVIEW.os, "pidfd_open", return_value=42, create=True), \
                    mock.patch.object(PREVIEW.signal, "pidfd_send_signal", create=True) as send_signal, \
                    mock.patch.object(PREVIEW.os, "close") as close_pidfd, \
                    contextlib.redirect_stdout(output):
                result = PREVIEW.stop(None)

            self.assertEqual(result, 1)
            self.assertIn("foreground terminal", output.getvalue())
            send_signal.assert_not_called()
            close_pidfd.assert_called_once_with(42)

    def test_stop_refuses_unsafe_fallback_without_pidfd_support(self):
        with tempfile.TemporaryDirectory() as temporary:
            state_root = pathlib.Path(temporary)
            (state_root / "active.pid").write_text(f"{os.getpid()} 123\n", encoding="ascii")
            output = io.StringIO()

            with mock.patch.object(PREVIEW, "STATE_ROOT", state_root), \
                    mock.patch.object(PREVIEW, "process_start_ticks", return_value=123), \
                    mock.patch.object(PREVIEW, "process_alive", return_value=True), \
                    mock.patch.object(PREVIEW.os, "pidfd_open", None, create=True), \
                    mock.patch.object(PREVIEW.signal, "pidfd_send_signal", None, create=True), \
                    mock.patch.object(PREVIEW.os, "kill") as kill, \
                    contextlib.redirect_stdout(output):
                result = PREVIEW.stop(None)

            self.assertEqual(result, 1)
            self.assertIn("foreground terminal", output.getvalue())
            kill.assert_not_called()

    def test_package_server_is_local_and_serves_only_requested_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            package_dir = pathlib.Path(temporary)
            package = package_dir / "preview.run"
            package.write_bytes(b"installer-content")
            (package_dir / "secret.txt").write_text("private", encoding="utf-8")
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                port = probe.getsockname()[1]

            with mock.patch.object(PREVIEW, "HTTP_PORT", port):
                server = PREVIEW.start_package_server(package)
            try:
                self.assertEqual(server.server_address[0], "127.0.0.1")
                with urlopen(f"http://127.0.0.1:{port}/preview.run", timeout=2) as response:
                    self.assertEqual(response.read(), b"installer-content")
                with self.assertRaises(HTTPError) as error:
                    urlopen(f"http://127.0.0.1:{port}/secret.txt", timeout=2)
                self.assertEqual(error.exception.code, 404)
                error.exception.close()
            finally:
                server.shutdown()
                server.server_close()

    def test_qemu_forwards_guest_package_requests_to_localhost_only(self):
        with mock.patch.object(PREVIEW, "HTTP_PORT", 19001):
            network = PREVIEW.qemu_network_config()

        self.assertIn("guestfwd=tcp:192.168.100.2:19001-tcp:127.0.0.1:19001", network)
        self.assertNotIn("0.0.0.0", network)

    def test_luci_readiness_accepts_login_required_but_rejects_missing_route(self):
        class Server(ThreadingHTTPServer):
            daemon_threads = True

        server = Server(("127.0.0.1", 0), LuCIHandler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            with mock.patch.object(PREVIEW, "LUCI_PORT", server.server_address[1]):
                LuCIHandler.status_code = 403
                LuCIHandler.login_header = "yes"
                self.assertEqual(PREVIEW.wait_for_luci(timeout=1), 403)

                LuCIHandler.status_code = 404
                LuCIHandler.login_header = None
                with mock.patch.object(PREVIEW.time, "sleep", return_value=None):
                    with self.assertRaises(TimeoutError):
                        PREVIEW.wait_for_luci(timeout=0.05)
        finally:
            server.shutdown()
            server_thread.join(timeout=2)
            server.server_close()


if __name__ == "__main__":
    unittest.main()
