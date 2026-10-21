"""Export only the Samsung Notes session into a password-encrypted Mac connection file."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import queue
import secrets
import sys
import time


def key_path(output):
    identity = hashlib.sha256(str(Path(output).resolve()).casefold().encode()).hexdigest()
    return Path(os.environ["LOCALAPPDATA"]) / "SamsungCloudNotes" / "ConnectionCodes" / (identity + ".dpapi")


def write_export(authorization, account, output):
    import win32crypt
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if not authorization.startswith("Bearer ") or any(c in authorization for c in "\r\n"):
        raise ValueError("Invalid Samsung session")
    key = secrets.token_bytes(32)
    nonce = secrets.token_bytes(12)
    session = json.dumps({"authorization": authorization, "account": account}).encode()
    sealed = nonce + AESGCM(key).encrypt(nonce, session, None)
    envelope = {"format": "samsung-cloud-notes-connection", "version": 1, "sealed": base64.b64encode(sealed).decode()}
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    destination = key_path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    protected_key = win32crypt.CryptProtectData(key, "Samsung Cloud Notes connection code", None, None, None, 0)
    destination.write_bytes(protected_key)
    temporary = output.with_suffix(".tmp")
    temporary.write_text(json.dumps(envelope, indent=2), encoding="utf-8")
    temporary.replace(output)
    return base64.b64encode(key).decode()


HOOK = r"""
const module = Process.findModuleByName('SamsungNotesSync_withSDK.dll');
if (!module) throw Error('Samsung Notes sync component is not loaded');
for (const name of ['WindowsCreateString', 'WindowsCreateStringReference']) {
    const address = Module.findGlobalExportByName(name);
    if (!address) continue;
    Interceptor.attach(address, {
        onEnter(args) {
            if (this.returnAddress.compare(module.base) < 0 || this.returnAddress.compare(module.base.add(module.size)) >= 0) return;
            const length = args[1].toUInt32();
            if (length < 32 || length > 16384) return;
            try {
                const value = args[0].readUtf16String(length);
                if (value.startsWith('Bearer ')) send({authorization: value});
            } catch (_) {}
        }
    });
}
"""


def collect_session(timeout, status=None, cancelled=None):
    import frida
    import psutil
    tokens = queue.Queue()
    sessions = []
    scripts = []
    report = status or (lambda value: print(value, flush=True))
    deadline = time.monotonic() + timeout
    attached = set()
    try:
        report("In Samsung Notes, sign in if needed, open Settings, then click Sync now.")
        while time.monotonic() < deadline:
            if cancelled is not None and cancelled.is_set():
                raise RuntimeError("Connection export cancelled.")
            for process in psutil.process_iter(["pid", "name"]):
                if (process.info["name"] or "").lower() not in {"samsungnotes.exe", "backgroundtaskhost.exe"} or process.pid in attached:
                    continue
                try:
                    if not any(m.path.lower().endswith("\\samsungnotessync_withsdk.dll") for m in process.memory_maps()):
                        continue
                    session = frida.attach(process.pid)
                    sessions.append(session)
                    script = session.create_script(HOOK)
                    def received(message, _data):
                        if message.get("type") == "send" and message.get("payload", {}).get("authorization"):
                            tokens.put(message["payload"]["authorization"])
                    script.on("message", received)
                    script.load()
                    scripts.append(script); attached.add(process.pid)
                    report("Ready. Click Sync now in Samsung Notes → Settings.")
                except (psutil.Error, OSError, frida.ProcessNotFoundError, frida.PermissionDeniedError, frida.InvalidOperationError):
                    continue
            try:
                return tokens.get(timeout=0.4)
            except queue.Empty:
                pass
        raise RuntimeError("No session was observed. Keep Samsung Notes open and signed in, then try again and click Sync now.")
    finally:
        for session in sessions:
            try:
                session.detach()
            except Exception:
                pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parent / "SamsungConnection.samsungconnection")
    parser.add_argument("--account", default="Samsung account", help="Display label; does not change the signed-in account")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--show-code", action="store_true")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Run this exporter on the Windows PC signed in to Samsung Notes.")
    try:
        if args.show_code:
            import win32crypt
            key = win32crypt.CryptUnprotectData(key_path(args.output).read_bytes(), None, None, None, 0)[1]
            print("Connection code:\n\n" + base64.b64encode(key).decode())
            return
        authorization = collect_session(args.timeout)
        code = write_export(authorization, args.account, args.output)
        print("\nEncrypted connection saved to:\n" + str(args.output))
        print("\nCopy that file to your Mac, choose Import connection in the app, then paste this code:\n\n" + code)
        print("\nTreat the file and code together like a password. This exporter has detached from Samsung Notes.")
    except Exception as error:
        print("Export failed: " + str(error), file=sys.stderr)
        raise SystemExit(1)


if __name__ == "__main__":
    main()
