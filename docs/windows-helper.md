# Windows connection helper 0.1.3

1. Open **SamsungNotesConnection.exe**. Nothing needs to be installed, and no Python setup is required.
2. Choose **Open Samsung Notes**. If needed, sign in inside Samsung Notes, including its normal 2FA.
3. In the helper, choose **Export connection** and save the encrypted file somewhere you will keep it.
4. In Samsung Notes, open **Settings**. When the helper says **Ready**, click **Sync now**.
5. Wait for **Connected!** in the helper. Copy the saved `.samsungconnection` file to your Mac.
6. Choose **Copy connection code**. On the signed-out Mac welcome screen, choose **Import Windows connection**, select the file and paste the code.

The file and code together grant Samsung Cloud Notes access. Keep both private. The helper validates Notes access with Samsung before exporting; it does not edit any note. After import, the Mac connects to Samsung directly. Windows is needed again if the session expires.

**Recover an earlier code** works on the exporting Windows account and original file path. Moving the file to another Windows path does not move its DPAPI-protected recovery record. You can always export a fresh pair.

**Cancel** detaches the capture hooks and enables another attempt. If cancellation happens during the cloud check, it may take up to the 20-second network timeout to finish. Closing the helper also cancels and waits for its worker to detach.

Copying schedules clipboard clearing after one minute while the helper is open. Closing also clears the code if it is still on the clipboard. The helper never clears unrelated clipboard contents.

If no connection is captured, keep the official app open, confirm it is signed in with sync enabled, retry Export, wait for Ready, then click Sync now. Capture was checked against Samsung Notes 4.3.831.0 on Windows x64; future Samsung updates may require an adjustment.

This helper reuses Samsung Notes' existing session. The helper itself does not renew exported sessions; the Mac app separately provides independent sign-in and renewal. The borrowed device identity and its limitations are described in the main README.

## Running from source

With the pinned runtime requirements installed on Windows:

```powershell
python scripts/connection_helper.py
```

The CLI fallback is `python scripts/export_connection.py --output <path>`. The two batch launchers in `scripts/` wrap export and recovery. The CLI prints the connection code in its terminal, so do not record or share that output. The GUI adds read-only cloud validation before export. See the main README for isolated-environment setup, tests and standalone packaging.
