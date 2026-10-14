"""Checks the real native driver; invoke with its compiled executable path."""

import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import platform
import select
import subprocess
import sys
import threading
import time
import unittest


EXECUTABLE = os.path.realpath(sys.argv.pop(1))
HANDSHAKE = {
    "id": "c:handshake",
    "command": "handshake",
    "args": {
        "protocolVersions": [1],
        "runId": "fd3-run",
        "requiredCapabilities": [],
        "target": {"language": "dart", "role": "sdk", "environment": "native"},
    },
}


class InheritedDescriptorTest(unittest.TestCase):
    def start(self):
        reader, writer = os.pipe()
        def inherit():
            if reader != 3:
                os.dup2(reader, 3)
                os.close(reader)
        process = subprocess.Popen(
            [EXECUTABLE, "--plain-sdk", "plain", "--auth-sdk", "auth"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            pass_fds=tuple({reader, 3}),
            preexec_fn=inherit,
        )
        os.close(reader)
        self.addCleanup(self.reap, process)
        return process, writer, time.monotonic() + 5

    def remaining(self, process, deadline):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            self.reap(process)
            self.fail("Native driver deadline exceeded.")
        return remaining

    def write(self, process, descriptor, data, deadline):
        os.set_blocking(descriptor, False)
        offset = 0
        while offset < len(data):
            if not select.select([], [descriptor], [], self.remaining(process, deadline))[1]:
                continue
            try:
                offset += os.write(descriptor, data[offset:])
            except BlockingIOError:
                pass

    def frame(self, process, deadline):
        descriptor = process.stdout.fileno()
        os.set_blocking(descriptor, False)
        data = bytearray()
        while len(data) < 16 * 1024 * 1024:
            if not select.select([descriptor], [], [], self.remaining(process, deadline))[0]:
                continue
            try:
                byte = os.read(descriptor, 1)
            except BlockingIOError:
                continue
            if not byte:
                self.fail("Native driver ended before a complete frame.")
            data.extend(byte)
            if byte == b"\n":
                return bytes(data)
        self.fail("Native driver frame exceeded the limit.")

    def communicate(self, process, deadline):
        try:
            return process.communicate(timeout=self.remaining(process, deadline))
        except subprocess.TimeoutExpired:
            self.reap(process)
            self.fail("Native driver deadline exceeded.")

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream:
                stream.close()

    def test_bootstrap_eof_then_control_eof_and_fresh_process(self):
        comparisons = []
        credential = "s" * 43

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                comparisons.append(self.headers.get("Authorization") == "Bearer " + credential)
                body = json.dumps({"wire_value": "native", "observed_at": "2026-01-01T00:00:00Z"}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        for _ in range(2):
            peer = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            process, writer, deadline = self.start()
            thread = threading.Thread(target=peer.serve_forever, daemon=True)
            thread.start()
            self.addCleanup(peer.server_close)
            self.addCleanup(peer.shutdown)
            frame = json.dumps({"ref": "protected", "value": credential}).encode() + b"\n"
            try:
                self.write(process, writer, frame, deadline)
                self.write(process, process.stdin.fileno(), json.dumps(HANDSHAKE).encode() + b"\n", deadline)
                self.assertFalse(select.select([process.stdout], [], [], 0.15)[0])
            finally:
                os.close(writer)
            response = self.frame(process, deadline)
            self.assertEqual(json.loads(response)["result"]["protocolVersion"], 1)
            for command, values in [
                ("client.create", {"clientRef": "native", "origin": "http://127.0.0.1:" + str(peer.server_port),
                                   "fixture": "plain", "requestTimeoutMs": 1000, "bearerRef": "protected"}),
                ("client.call", {"clientRef": "native", "operation": "probe.echo", "input": {"wire_value": "native"}}),
            ]:
                values.update({"caseId": "native", "timeoutMs": 5000})
                self.write(process, process.stdin.fileno(), json.dumps({"id": "c:" + command, "command": command, "args": values}).encode() + b"\n", deadline)
                row = self.frame(process, deadline)
                self.assertTrue(json.loads(row)["error"] is None, "Native SDK command failed.")
                self.assertTrue(credential.encode() not in row, "Protected value exposed.")
            command = {"id": "c:observe", "command": "client.observe",
                       "args": {"caseId": "native", "timeoutMs": 5000,
                                "callId": "c:client.call", "afterSequence": 0}}
            self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
            observed = json.loads(self.frame(process, deadline))
            self.assertIsNone(observed["error"], "Native transport snapshot failed.")
            snapshot = observed["result"]
            self.assertTrue(snapshot["complete"])
            self.assertEqual(snapshot["events"][-1]["phase"], "completed")
            self.assertTrue(all(set(event) == {"sequence", "callId", "elapsedMs", "phase",
                                              "httpStatus", "readBytes", "retainedBytes",
                                              "peakRetainedBytes"} for event in snapshot["events"]))
            self.assertTrue(all(event["retainedBytes"] is not None and event["peakRetainedBytes"] is not None
                                for event in snapshot["events"]), "Proven native retention missing.")
            command["id"] = "c:observe:next"
            command["args"]["afterSequence"] = snapshot["throughSequence"]
            self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
            self.assertEqual(json.loads(self.frame(process, deadline))["result"]["events"], [])
            process.stdin.close()
            process.stdin = None
            stdout, stderr = self.communicate(process, deadline)
            self.assertEqual(process.returncode, 0)
            self.assertFalse(bool(stdout), "Unexpected protocol output.")
            self.assertTrue(credential.encode() not in response + stdout + stderr,
                            "Protected value exposed.")
            peer.shutdown()
            thread.join()
            peer.server_close()
        self.assertEqual(comparisons, [True, True])
        print(json.dumps({"bootstrapBytes": len(frame), "referencesMatched": True,
                          "bootstrapEOFBeforeHandshake": True, "controlEOF": True,
                          "exitObserved": True, "freshProcesses": 2}), flush=True)

    def test_redirect_reader_closure_waits_for_native_cancellation(self):
        self.redirect_reader_closure(False)

    def test_session_refresh_redirect_preserves_native_reader_closure(self):
        self.redirect_reader_closure(True)

    def redirect_reader_closure(self, session):
        closed = threading.Event()
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                self.rfile.read(int(self.headers["Content-Length"]))
                requests.append(self.path)
                if session and self.path == "/probe.echo":
                    body = json.dumps({"error": "invalid_token"}).encode()
                    self.send_response(401)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                self.send_response(302)
                self.send_header("Content-Length", str(2 * 1024 * 1024 + 1))
                self.send_header("Location", "/sink")
                self.end_headers()
                self.wfile.flush()
                try:
                    self.wfile.write(b"x" * 65536)
                    self.wfile.flush()
                    self.connection.settimeout(2)
                    if not self.connection.recv(1):
                        closed.set()
                except (ConnectionResetError, BrokenPipeError):
                    closed.set()

            def log_message(self, *args):
                pass

        peer = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=peer.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(peer.server_close)
        self.addCleanup(peer.shutdown)
        process, writer, deadline = self.start()
        origin = "http://127.0.0.1:" + str(peer.server_port)
        if session:
            record = {"origin": origin, "access_token": "a" * 43, "refresh_token": "r" * 43,
                      "expires_at": "2099-01-01T00:00:00Z", "refresh_expires_at": "2099-02-01T00:00:00Z",
                      "user_id": "user", "session_id": "session"}
            for ref, value in [("record", json.dumps(record)), ("access", record["access_token"]),
                               ("refresh", record["refresh_token"])]:
                self.write(process, writer, json.dumps({"ref": ref, "value": value}).encode() + b"\n", deadline)
        os.close(writer)
        commands = [HANDSHAKE]
        if session:
            commands.append({"id": "c:store", "command": "session.store.create", "args": {
                "caseId": "redirect", "timeoutMs": 5000, "storeRef": "store", "origin": origin,
                "recordRef": "record", "accessRef": "access", "refreshRef": "refresh"}})
        commands.extend([
                        {"id": "c:create", "command": "client.create", "args": {
                            "caseId": "redirect", "timeoutMs": 5000, "clientRef": "client", "fixture": "plain",
                            "origin": origin, "requestTimeoutMs": 1000,
                            **({"storeRef": "store"} if session else {})}},
                        {"id": "c:call", "command": "client.call", "args": {
                            "caseId": "redirect", "timeoutMs": 5000, "clientRef": "client",
                            "operation": "probe.echo", "input": {"wire_value": "value"}}}])
        for command in commands:
            self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
            response = json.loads(self.frame(process, deadline))
            if command["command"] != "client.call":
                self.assertIsNone(response["error"], "Native setup failed.")
        self.assertEqual(response["error"]["code"], "redirect_not_allowed")
        self.assertEqual(response["error"]["httpStatus"], 302)
        events, through, queries = [], 0, 0
        while not any(event["phase"] == "reader-closed" for event in events):
            command = {"id": "c:observe:" + str(queries), "command": "client.observe", "args": {
                "caseId": "redirect", "timeoutMs": 5000, "callId": "c:call", "afterSequence": through}}
            self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
            snapshot = json.loads(self.frame(process, deadline))["result"]
            self.assertEqual(snapshot["complete"],
                             all(event[field] is not None for event in snapshot["events"]
                                 for field in ("readBytes", "retainedBytes", "peakRetainedBytes")))
            events.extend(snapshot["events"])
            through, queries = snapshot["throughSequence"], queries + 1
        phases = [event["phase"] for event in events]
        self.assertLess(phases.index("cancel-requested"), phases.index("cancel-observed"))
        self.assertLess(phases.index("cancel-observed"), phases.index("reader-closed"))
        if not session:
            self.assertNotIn("read", phases)
        self.assertEqual(phases.count("headers"), 1)
        self.assertEqual(phases.count("cancel-observed"), 1)
        self.assertEqual(phases.count("reader-closed"), 1)
        self.assertEqual(phases.count("completed"), 1)
        self.assertTrue(all(event["httpStatus"] == 302 for event in events if event["phase"] != "read"))
        self.assertEqual([event["sequence"] for event in events],
                         sorted(set(event["sequence"] for event in events)))
        self.assertLessEqual(events[phases.index("reader-closed")]["elapsedMs"] - events[0]["elapsedMs"], 1000)
        self.assertTrue(closed.wait(self.remaining(process, deadline)))
        self.assertEqual(requests, ["/probe.echo", "/auth.refresh"] if session else ["/probe.echo"])
        command["id"] = "c:observe:exhausted"
        command["args"]["afterSequence"] = through
        self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
        self.assertEqual(json.loads(self.frame(process, deadline))["result"]["events"], [])
        process.stdin.close()
        process.stdin = None
        stdout, stderr = self.communicate(process, deadline)
        self.assertEqual(process.returncode, 0)
        self.assertFalse(bool(stdout + stderr), "Unexpected protocol output.")

    def test_invalid_bootstrap_is_finite_and_secret_free(self):
        credential = "s" * 43
        valid = json.dumps({"ref": "protected", "value": credential}).encode() + b"\n"
        variants = [
            valid + valid,
            valid[:-1],
            b'{"ref":"x","value":"s","extra":true}\n',
            b'{"ref":"x","value":"s","value":"t"}\n',
            b"x" * (64 * 1024),
            b"".join(json.dumps({"ref": "entry:" + str(i), "value": "x" * 60000}).encode()
                     + b"\n" for i in range(18)),
        ]
        for data in variants:
            with self.subTest(length=len(data)):
                process, writer, deadline = self.start()
                try:
                    self.write(process, writer, data, deadline)
                except BrokenPipeError:
                    pass
                finally:
                    os.close(writer)
                stdout, stderr = self.communicate(process, deadline)
                self.assertEqual(process.returncode, 2)
                self.assertFalse(bool(stdout), "Unexpected protocol output.")
                self.assertTrue(credential.encode() not in stdout + stderr,
                                "Protected value exposed.")

    def test_unclosed_bootstrap_does_not_complete_handshake(self):
        process, writer, deadline = self.start()
        try:
            self.write(process, process.stdin.fileno(), json.dumps(HANDSHAKE).encode() + b"\n", deadline)
            self.assertFalse(select.select([process.stdout], [], [], 0.15)[0])
            process.terminate()
            self.communicate(process, deadline)
            self.assertIsNotNone(process.returncode)
        finally:
            os.close(writer)

    def test_fatal_commands_exit_with_stdin_open(self):
        for failure in ("protocol_mismatch", "deadline_exceeded", "protocol_violation"):
            with self.subTest(failure=failure):
                process, writer, deadline = self.start()
                os.close(writer)
                handshake = json.loads(json.dumps(HANDSHAKE))
                if failure == "protocol_mismatch":
                    handshake["args"]["protocolVersions"] = [2]
                self.write(process, process.stdin.fileno(), json.dumps(handshake).encode() + b"\n", deadline)
                response = json.loads(self.frame(process, deadline))
                if failure == "protocol_violation":
                    self.assertIsNone(response["error"], "Native handshake failed.")
                    command = {"id": "c:mixed", "command": "session.store.create",
                               "args": {"caseId": "fatal", "timeoutMs": 0, "storeRef": "store",
                                        "origin": "http://127.0.0.1", "extra": True}}
                    self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
                    response = json.loads(self.frame(process, deadline))
                if failure == "deadline_exceeded":
                    self.assertIsNone(response["error"], "Native handshake failed.")
                    release = threading.Event()

                    class Handler(BaseHTTPRequestHandler):
                        def do_POST(self):
                            self.rfile.read(int(self.headers["Content-Length"]))
                            release.wait(2)

                        def log_message(self, *args):
                            pass

                    peer = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
                    thread = threading.Thread(target=peer.serve_forever, daemon=True)
                    thread.start()
                    self.addCleanup(peer.server_close)
                    self.addCleanup(peer.shutdown)
                    self.addCleanup(release.set)
                    for command, values in [
                        ("client.create", {"clientRef": "slow", "origin": "http://127.0.0.1:" + str(peer.server_port),
                                           "fixture": "plain", "requestTimeoutMs": 2000, "timeoutMs": 2000}),
                        ("client.call", {"clientRef": "slow", "operation": "probe.echo",
                                         "input": {"wire_value": "slow"}, "timeoutMs": 50}),
                    ]:
                        values["caseId"] = "fatal"
                        self.write(process, process.stdin.fileno(), json.dumps({"id": "c:" + command,
                                   "command": command, "args": values}).encode() + b"\n", deadline)
                        response = json.loads(self.frame(process, deadline))
                        if command == "client.create":
                            self.assertIsNone(response["error"], "Native client creation failed.")
                self.assertEqual(response["error"]["code"], failure)
                try:
                    process.wait(timeout=self.remaining(process, deadline))
                except subprocess.TimeoutExpired:
                    self.reap(process)
                    self.fail("Native driver deadline exceeded.")
                self.assertEqual(process.returncode, 2)
                self.assertFalse(process.stdin.closed, "Control input closed before fatal exit.")

    def test_invalid_timeout_is_request_error_and_next_command_progresses(self):
        process, writer, deadline = self.start()
        os.close(writer)
        self.write(process, process.stdin.fileno(), json.dumps(HANDSHAKE).encode() + b"\n", deadline)
        self.assertIsNone(json.loads(self.frame(process, deadline))["error"], "Native handshake failed.")
        for index, timeout in enumerate((0, -1, "5000", 5000)):
            command = {"id": "c:timeout:" + str(index), "command": "session.store.create",
                       "args": {"caseId": "timeouts", "timeoutMs": timeout,
                                "storeRef": "store", "origin": "http://127.0.0.1"}}
            self.write(process, process.stdin.fileno(), json.dumps(command).encode() + b"\n", deadline)
            response = json.loads(self.frame(process, deadline))
            self.assertEqual(response["id"], command["id"])
            if timeout == 5000:
                self.assertIsNone(response["error"], "Valid command after invalid timeout failed.")
            else:
                self.assertIsNone(response["result"])
                self.assertEqual(response["error"]["kind"], "driver")
                self.assertEqual(response["error"]["code"], "invalid_args")
        process.stdin.close()
        process.stdin = None
        stdout, stderr = self.communicate(process, deadline)
        self.assertEqual(process.returncode, 0)
        self.assertFalse(bool(stdout + stderr), "Unexpected protocol output.")


if __name__ == "__main__":
    with open(EXECUTABLE, "rb") as artifact:
        digest = hashlib.sha256(artifact.read()).hexdigest()
    print(json.dumps({"os": platform.system(), "arch": platform.machine(),
                      "executableSHA256": digest}), flush=True)
    unittest.main()
