# Third-party notices

The macOS and iOS apps use Apple's system frameworks and contain an original Swift implementation and original icon artwork. Samsung Notes and Samsung Cloud are Samsung trademarks; this project is unofficial and unaffiliated. No Samsung application, SDK or icon is bundled.

The Windows connection helper packages the following existing runtime components. Their license texts are retained in `docs/third-party` and bundled under `notices` in the executable:

| Component | Version used | License |
| --- | --- | --- |
| CPython | 3.14.3 | Python Software Foundation license and bundled notices |
| Tcl/Tk | 8.6 | Tcl/Tk license terms |
| Frida | 17.9.3 | wxWindows Library Licence 3.1 |
| psutil | 7.2.2 | BSD-3-Clause |
| pywin32 | 312 | Python license and component notices |
| cryptography | 46.0.7 | Apache-2.0 or BSD-3-Clause, with bundled dependency notices |
| cffi | 2.0.0 | MIT |
| pycparser | 3.0 | BSD-3-Clause |
| PyInstaller bootloader | 6.19.0 | GPL with the PyInstaller distribution exception |

The build uses PyInstaller; its exception permits distribution of the packaged application under the application's own terms. Original project code and artwork are MIT licensed; see the root LICENSE. These third-party license terms remain in effect for their respective components.

The Android app contains an original Kotlin port of that implementation and bundles these Apache-2.0 libraries from Google's Maven repository (license: https://www.apache.org/licenses/LICENSE-2.0): AndroidX Activity, Browser, Core, Lifecycle, Jetpack Compose (UI, Foundation, Material 3, Material Icons) and Kotlin's standard library and coroutines (JetBrains, Apache-2.0). Their notices are carried in the libraries' own artifacts. The APK also contains this file, the project LICENSE and the samsung-re-health license under `assets/notices`.

The handwriting decoder consulted [sdocx's format research](https://github.com/twangodev/sdocx). No sdocx source is bundled. Other research references are described in the README.

## Native account and SCSP protocol adaptation

The account bootstrap, encryption envelope and SCSP identity exchange in `Sources/Shared/Authentication.swift` were adapted in Swift after consulting [samsung-re-health](https://github.com/charlesbel/samsung-re-health), Copyright (c) 2026 Charles Bel, MIT License, and ported to Kotlin in `android/app/src/main/java/local/samsungcloudnotes/Auth.kt`. Its complete license is retained in `docs/third-party/samsung-re-health-LICENSE.txt` and included in the Mac app resources, the iOS app's `Notices` folder and the Android APK's `assets/notices`. No Python implementation or Samsung SDK is bundled in any app.
