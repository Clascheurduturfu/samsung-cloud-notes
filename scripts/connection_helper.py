"""Desktop bridge to the official Windows Samsung Notes sign-in session."""
import base64
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import ttk, filedialog, messagebox
import urllib.error
import urllib.request

from export_connection import collect_session, write_export, key_path

VERSION = "0.1.3"


def launch_samsung_notes():
    # Resolve the installed package instead of embedding its versioned path.
    command = "$p=Get-AppxPackage SAMSUNGELECTRONICSCoLtd.SamsungNotes; if(!$p){exit 2}; $a=(Get-AppxPackageManifest $p).Package.Applications.Application | Select-Object -First 1; Write-Output ($p.PackageFamilyName+'!'+$a.Id)"
    result = subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command],
                            capture_output=True, text=True, timeout=15, creationflags=subprocess.CREATE_NO_WINDOW)
    identity = result.stdout.strip()
    if result.returncode or not identity.startswith("SAMSUNGELECTRONICSCoLtd.SamsungNotes_") or any(c in identity for c in "\r\n"):
        raise RuntimeError("Install Samsung Notes from the Microsoft Store first, then sign in to your Samsung account there.")
    subprocess.Popen(["explorer.exe", "shell:AppsFolder\\" + identity])


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def validate_session(authorization):
    # Read-only request. Never write the token or server response to a log.
    cursor = base64.b64encode(json.dumps({"version": 0, "encryptedGuid": "", "requestTimeStamp": 0,
        "modifiedTime": 0, "appVersion": "0", "sdkVersion": "0", "purpose": "INITIAL", "type": "NOTE"}).encode()).decode()
    from urllib.parse import urlencode
    request = urllib.request.Request("https://api.samsungcloud.com/samsungnotes/v1/notes/changes?" + urlencode({"lastChangePoint": cursor}),
        headers={"Authorization": authorization, "x-sn-sdk-ver": "5500", "x-sn-app-ver": "4000", "X-SN-XML-VER": "2", "X-SN-Feature-ID": "O4vARCbQ3G"})
    try:
        with urllib.request.build_opener(NoRedirect).open(request, timeout=20) as response:
            import xml.etree.ElementTree as ET
            if ET.fromstring(response.read()).tag != "NoteChangesView":
                raise RuntimeError("Samsung returned an unexpected Notes response. Try Sync now again.")
    except urllib.error.HTTPError as error:
        raise RuntimeError("Samsung rejected this connection (HTTP %s). Sign in and sync in Samsung Notes, then try again." % error.code) from None
    except (urllib.error.URLError, TimeoutError):
        raise RuntimeError("Could not reach Samsung Cloud. Check the connection and try again.") from None


def create_connection(output, label, cancelled, status):
    authorization = collect_session(180, status=status, cancelled=cancelled)
    if cancelled.is_set(): return None
    status("Checking Notes access with Samsung Cloud…")
    validate_session(authorization)
    if cancelled.is_set(): return None
    return write_export(authorization, label, output)


class ConnectionHelper:
    def __init__(self, root):
        self.root = root
        root.title("Samsung Cloud Notes · Connection helper")
        root.geometry("620x570"); root.minsize(600, 540)
        self.events = queue.Queue(); self.cancelled = threading.Event(); self.worker = None
        self.code = ""; self.output = None; self.closing = False
        style = ttk.Style(); style.theme_use("vista")
        style.configure("Title.TLabel", font=("Segoe UI", 20, "bold"))
        style.configure("Accent.TButton", padding=9)
        frame = ttk.Frame(root, padding=24); frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="Connect your Mac to Samsung Notes", style="Title.TLabel", wraplength=560).pack(anchor="w")
        ttk.Label(frame, text="Connection helper " + VERSION + " · Windows", foreground="#666666").pack(anchor="w", pady=(4, 18))
        ttk.Label(frame, text="1. Open Samsung Notes and sign in there.\n2. Choose Export connection below.\n3. In Samsung Notes → Settings, click Sync now.", justify="left", wraplength=550).pack(anchor="w")
        self.open_button = ttk.Button(frame, text="Open Samsung Notes", command=self.open_notes)
        self.open_button.pack(anchor="w", pady=(12, 16))
        ttk.Label(frame, text="Account label (optional, for your Mac sidebar)").pack(anchor="w")
        self.account = tk.StringVar(value="Samsung account")
        self.account_entry = ttk.Entry(frame, textvariable=self.account); self.account_entry.pack(fill="x", pady=(4, 12))
        row = ttk.Frame(frame); row.pack(fill="x")
        self.export_button = ttk.Button(row, text="Export connection…", style="Accent.TButton", command=self.start); self.export_button.pack(side="left")
        self.cancel_button = ttk.Button(row, text="Cancel", command=self.cancel, state="disabled"); self.cancel_button.pack(side="left", padx=8)
        self.progress = ttk.Progressbar(frame, mode="indeterminate"); self.progress.pack(fill="x", pady=(16, 8))
        self.status = tk.StringVar(value="Your password and 2FA stay in Samsung’s own app.")
        ttk.Label(frame, textvariable=self.status, wraplength=550, justify="left").pack(anchor="w")
        ttk.Separator(frame).pack(fill="x", pady=14)
        self.reveal = tk.BooleanVar(value=False)
        self.code_value = tk.StringVar()
        self.code_entry = ttk.Entry(frame, textvariable=self.code_value, state="readonly", show="•"); self.code_entry.pack(fill="x")
        bottom = ttk.Frame(frame); bottom.pack(fill="x", pady=6)
        self.copy_button = ttk.Button(bottom, text="Copy connection code", command=self.copy_code, state="disabled"); self.copy_button.pack(side="left")
        ttk.Checkbutton(bottom, text="Show code", variable=self.reveal, command=lambda: self.code_entry.configure(show="" if self.reveal.get() else "•")).pack(side="left", padx=10)
        ttk.Button(bottom, text="Recover an earlier code…", command=self.recover).pack(side="right")
        ttk.Label(frame, text="Copy the encrypted .samsungconnection file to your Mac, import it, then paste the code. Keep them private; together they grant account access.", wraplength=550, foreground="#666666").pack(anchor="w", pady=(8, 0))
        root.protocol("WM_DELETE_WINDOW", self.close)
        root.after(100, self.poll)

    def open_notes(self):
        def work():
            try: launch_samsung_notes()
            except Exception as error: self.events.put(("launch-error", str(error)))
        threading.Thread(target=work, daemon=True).start()

    def start(self):
        if self.worker and self.worker.is_alive(): return
        path = filedialog.asksaveasfilename(parent=self.root, title="Save encrypted Mac connection", initialfile="SamsungConnection.samsungconnection", defaultextension=".samsungconnection", filetypes=[("Samsung connection", "*.samsungconnection")])
        if not path: return
        self.output = Path(path); label = self.account.get().strip() or "Samsung account"
        self.cancelled.clear(); self.code = ""; self.code_value.set(""); self.copy_button.configure(state="disabled")
        self.open_button.configure(state="disabled"); self.export_button.configure(state="disabled"); self.account_entry.configure(state="disabled"); self.cancel_button.configure(state="normal"); self.progress.start(12)
        self.status.set("Open Samsung Notes → Settings, then click Sync now. Waiting up to three minutes…")
        def work():
            try:
                code = create_connection(self.output, label, self.cancelled, lambda text: self.events.put(("status", text)))
                if code is not None: self.events.put(("done", code))
            except Exception as error: self.events.put(("error", str(error)))
            finally: self.events.put(("finished", ""))
        self.worker = threading.Thread(target=work, daemon=False); self.worker.start()

    def cancel(self):
        self.cancelled.set(); self.status.set("Cancelling and detaching from Samsung Notes…")

    def recover(self):
        if self.worker and self.worker.is_alive(): return
        path = filedialog.askopenfilename(parent=self.root, title="Select your earlier connection file", filetypes=[("Samsung connection", "*.samsungconnection")])
        if not path: return
        try:
            import win32crypt
            self.code = base64.b64encode(win32crypt.CryptUnprotectData(key_path(path).read_bytes(), None, None, None, 0)[1]).decode()
            self.code_value.set(self.code); self.copy_button.configure(state="normal")
            self.status.set("Code recovered on its original Windows account. Import the matching file on your Mac.")
        except Exception:
            messagebox.showerror("Code unavailable", "This code can only be recovered by the Windows user who exported this file, at its original path.", parent=self.root)

    def copy_code(self):
        if not self.code: return
        self.root.clipboard_clear(); self.root.clipboard_append(self.code)
        value = self.code
        def clear():
            try:
                if self.root.clipboard_get() == value: self.root.clipboard_clear()
            except tk.TclError: pass
        self.root.after(60_000, clear)
        self.status.set("Code copied. Paste it into the Mac’s Import connection window. Clipboard clears after one minute while this helper is open.")

    def poll(self):
        try:
            while True:
                kind, value = self.events.get_nowait()
                if kind == "status": self.status.set(value)
                elif kind == "finished":
                    self.progress.stop(); self.progress.configure(value=0)
                    self.open_button.configure(state="normal"); self.export_button.configure(state="normal"); self.account_entry.configure(state="normal"); self.cancel_button.configure(state="disabled")
                    if self.cancelled.is_set(): self.status.set("Cancelled. Detached from Samsung Notes; you can try again.")
                else:
                    if kind == "done":
                        self.code = value; self.code_value.set(value); self.copy_button.configure(state="normal")
                        self.status.set("Connected! Encrypted file saved to " + str(self.output) + ". Copy it and the code to your Mac.")
                    else: self.status.set(value)
        except queue.Empty: pass
        if self.closing and not (self.worker and self.worker.is_alive()): self.finish_close(); return
        self.root.after(100, self.poll)

    def close(self):
        self.closing = True; self.cancel()
        if not (self.worker and self.worker.is_alive()): self.finish_close()

    def finish_close(self):
        try:
            if self.code and self.root.clipboard_get() == self.code: self.root.clipboard_clear()
        except tk.TclError: pass
        self.root.destroy()


if __name__ == "__main__":
    import ctypes
    ctypes.windll.shcore.SetProcessDpiAwareness(1)
    root = tk.Tk()
    icon = Path(getattr(sys, "_MEIPASS", Path(__file__).parent.parent)) / "Assets" / "AppIcon.ico"
    if icon.exists(): root.iconbitmap(str(icon))
    ConnectionHelper(root); root.mainloop()
