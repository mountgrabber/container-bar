# Container Bar

A lightweight macOS status bar app that helps you view and control Linux containers managed by Apple’s container tool. It shows all current containers (running and stopped), lets you start/stop them from the menu, and automatically starts the container system services on launch.

## Requirements

- macOS 26 or later
- Apple silicon (arm64)
- Xcode 15 or later
- Apple’s container CLI installed at `/usr/local/bin/container`
  - You can obtain the signed installer from the official GitHub releases of the [container](https://github.com/apple/container) project.

## Features

- Status bar app (agent) with no Dock icon
- Lists containers (running and stopped) using `container list` / `ls`
- Start/Stop containers from the menu
- Automatically runs `container system start` on app launch
- Minimal footprint; no main window

## Build and Run

1. **Clone the repository**
   ```bash
   git clone https://github.com/mountgrabber/container-bar.git
   cd container-bar
   ```

2. **Open in Xcode**
   - Open `Container Bar.xcodeproj` (or `.xcworkspace` if you use SwiftPM dependencies).
   - Select the **"Container Bar"** target.

3. **Configure capabilities and Info**
   - Ensure **App Sandbox** is disabled (this app launches external processes).
     - *Xcode → Target → Signing & Capabilities → remove or disable "App Sandbox".*
   - Make sure the app is an agent (no Dock icon):
     - Add to `Info.plist`: `Application is agent (UIElement)` = `YES`
   - *Optional:* Set display name
     - `Info.plist` → `Bundle display name (CFBundleDisplayName)` = `Container Bar`

4. **Build and run**
   - *Product → Run*
   - The app will place an icon in the macOS status bar.
   - On first launch, it will attempt `container system start` (non-blocking).
   - Click the status bar icon to see the list of containers and Start/Stop actions.

## Installing Apple’s container CLI

- Download the latest signed installer package from the official container release page.
- Double-click the package and follow the instructions (admin password required).
- Verify the binary path:
  ```bash
  which container
  ```
  *Expected:* `/usr/local/bin/container`
- Start system services (manual one-time, if needed):
  ```bash
  /usr/local/bin/container system start
  ```

## Removing the "Quarantine" Attribute (if needed)

If you built or downloaded the app and macOS flags it as quarantined (won’t launch or shows security prompts), remove the quarantine attribute:

- In Terminal, run:
  ```bash
  xattr -l "/path/to/Container Bar.app"
  ```
- If you see `com.apple.quarantine`, remove it:
  ```bash
  xattr -d com.apple.quarantine "/path/to/Container Bar.app"
  ```

- **If you’re distributing a zipped app:**
  - The quarantine attribute may be applied when unzipping. Consider removing it after unzipping as shown above.

- **If you see permission issues with the container CLI:**
  - Check for quarantine on the CLI binary:
    ```bash
    sudo xattr -l /usr/local/bin/container
    ```
  - If present, remove it:
    ```bash
    sudo xattr -d com.apple.quarantine /usr/local/bin/container
    ```
  - Ensure it’s executable and owned by `root:wheel` (typical after the signed installer):
    ```bash
    ls -l /usr/local/bin/container
    ```
    *Should be at least:* `-rwxr-xr-x`

## Troubleshooting

- **Status bar shows only running containers**
  - Your container version may require the `--all` flag. The app uses `list --all` (or `ls --all`) to obtain stopped containers. If your CLI doesn’t support it, you’ll see only running containers.

- **First click shows “Unable to obtain a task name port right…” once**
  - This is a harmless system log from the scene/Control Center subsystem when the status item initializes. Subsequent interactions should be normal.

- **“The file “container” doesn’t exist” but it’s installed**
  - Ensure the app is not sandboxed (App Sandbox disabled).
  - Confirm `/usr/local/bin/container` exists and is executable.
  - Remove quarantine if present (see above).
  - Restart the app.

- **“Plugin ‘container-ps’ not found”**
  - This app uses `list`/`ls` instead of `ps`. Confirm your container supports:
    ```bash
    /usr/local/bin/container list
    /usr/local/bin/container list --all
    ```

- **“container system start failed”**
  - It may already be running, or the system service is unavailable. You can start it manually:
    ```bash
    /usr/local/bin/container system start
    ```

## Security and Permissions

- This app launches an external binary (`/usr/local/bin/container`). For this reason, it should not be sandboxed.
- If you need a sandboxed distribution, you’ll have to split launching into a helper tool (for example, XPC service or `SMJobBless` helper) that runs outside the sandbox. That is out of scope for this minimal sample.

## Contributing

Pull requests and issues are welcome. Please open an issue to discuss significant changes before submitting a PR.

## Support

- For container CLI usage, consult the official documentation and release notes.
- For app issues, file an issue in this repository with:
  - macOS version
  - container version and output of:
    ```bash
    /usr/local/bin/container list
    /usr/local/bin/container list --all
    ```
  - Any console logs from the app (*View → Debug Area → Activate Console* in Xcode).
