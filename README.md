<p align="center">
  <img src="./assets/AppIcon/Hypervisaur-2048.png" width="160" alt="The Hypervisaur app icon, a T. rex head on a teal background">
</p>

<h1 align="center">Hypervisaur</h1>

<p align="center">Run macOS, Linux and Windows 11 virtual machines on Apple silicon Macs.</p>

<p align="center">
  <img src="./assets/Screenshots/Windows.png" width="800" alt="Windows 11 at its desktop in a Hypervisaur window">
</p>

## About this project

Hypervisaur is a fork of [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) by Guilherme Rambo. Almost everything that makes it work for macOS and Linux virtual machines is his work, and it keeps VirtualBuddy's BSD license and copyright notice. It's an independent project, not affiliated with or endorsed by VirtualBuddy, so please report problems with Hypervisaur here rather than to VirtualBuddy.

Hypervisaur adds Windows 11 virtual machines, running with QEMU, and a server that lets coding agents create and run virtual machines. Much of that was written with [Claude Code](https://claude.com/claude-code), Anthropic's coding agent, and reviewed and tested on real virtual machines. VirtualBuddy doesn't accept contributions written with AI tools, which is why these changes live in a fork instead.

## Features

<p align="center">
  <img src="./assets/Screenshots/Library.png" width="560" alt="The Hypervisaur library window with a Windows virtual machine">
</p>

- **macOS virtual machines** on macOS 12 or later, using Apple's Virtualization framework, with the macOS versions available to download kept up to date from this repository
- **Linux virtual machines** from Ubuntu, Fedora, Debian and Kali, always downloading the newest image of each release, or from any ARM64 disc image
- **Windows 11 virtual machines**, installed from Microsoft's Windows 11 ARM64 disc image, optionally without going through Windows Setup at all
- Clipboard sharing for macOS, Linux and Windows guests, and shared folders and saved sessions for macOS guests
- Screenshots and screen recordings of any virtual machine, with its sound
- Clones that run alongside the original and only take up the space of what's changed
- Importing virtual machines from VirtualBuddy and UTM
- An [MCP](https://modelcontextprotocol.io) server, so a coding agent can build a Windows virtual machine for you

## Requirements

- A Mac with Apple silicon
- macOS 14 or later
- For Windows virtual machines, [Homebrew](https://brew.sh) and the [Windows 11 ARM64 disc image](https://www.microsoft.com/software-download/windows11arm64) from Microsoft

## Installing

Download the installer package from the latest release on the [Releases](../../releases) page and open it. It installs Hypervisaur in your Applications folder.

Hypervisaur doesn't update itself yet. Check the Releases page for new versions.

## Windows virtual machines

Choose Windows when creating a virtual machine. Hypervisaur first checks for what Windows needs on your Mac, and installs anything that's missing with a single click:

| Component | What it's for |
| --- | --- |
| [QEMU](https://www.qemu.org) | Runs Windows with the Hypervisor framework, using the UEFI firmware that comes with it |
| [swtpm](https://github.com/stefanberger/swtpm) | The TPM 2.0 that Windows 11 requires |
| [wimlib](https://wimlib.net) | Copies the Windows installer onto a disk that the virtual machine can start from quickly |
| [7-Zip](https://www.7-zip.org) | Unpacks the SPICE agent, which shares the clipboard, from UTM's guest tools |
| Windows drivers | The virtio drivers for the network adapter, display and other devices, signed by Microsoft, and the SPICE agent. They're downloaded from [UTM's guest tools](https://github.com/utmapp/qemu/releases) and checked against a known checksum |

QEMU, swtpm, wimlib and 7-Zip come from Homebrew, which you need to install yourself. Then choose the Windows disc image and give the virtual machine a name. With **Set Up Windows Automatically**, Windows installs without asking anything and signs in to a local account with the name and optional password you choose. Without it, you go through Windows Setup as usual.

Installing takes about 10 minutes. Windows Setup uses a basic 800×600 display; afterwards, Windows uses the resolution in the virtual machine's display settings.

### Things to know

- You need your own Windows license. Windows is installed without a product key, so it isn't activated until you activate it.
- Windows virtual machines use NAT networking, sound output and a fixed display resolution that you can change in the virtual machine's settings. Shared folders, USB devices and saved sessions aren't available for Windows yet.
- Text you copy on your Mac can be pasted in Windows, and the other way round. You can turn this off with Share Clipboard in the virtual machine's settings. Windows virtual machines set up with Hypervisaur 0.1.0 need the clipboard agent installing once: in Windows, open the DRIVERS disk, then right-click `VirtIODrivers\Setup.cmd` and choose Run as Administrator. After that, Windows keeps what's installed from the DRIVERS disk up to date by itself.
- The firmware that comes with QEMU doesn't support Secure Boot, so Windows Setup is told to skip that check.

## Using Hypervisaur from a coding agent

Hypervisaur includes `vbmcp`, a [Model Context Protocol](https://modelcontextprotocol.io) server. Add it to Claude Code with:

```bash
claude mcp add hypervisaur -- "/Applications/Hypervisaur.app/Contents/MacOS/vbmcp"
```

Then ask for something like "Build a Windows VM with a local user called neil, an 80 GB disk and 6 GB of memory". The agent creates the virtual machine, starts it in Hypervisaur and waits until Windows is signed in at the desktop. The first time, Hypervisaur asks whether to allow the server to control your virtual machines.

| Tool | What it does |
| --- | --- |
| `create_windows_vm` | Creates a Windows 11 virtual machine and installs Windows without interaction |
| `wait_for_windows_vm` | Waits until Windows is signed in at the desktop, reporting progress |
| `get_windows_vm_status` | Tells whether Windows is installing, starting up or signed in |
| `list_virtual_machines` | Lists the virtual machines in the library |
| `start_vm`, `stop_vm` | Starts a virtual machine, or asks it to shut down |
| `take_screenshot` | Returns a screenshot of a running virtual machine, so the agent can see what's on its display |
| `clone_vm` | Makes a clone of a virtual machine that can run alongside it |
| `get_windows_requirements`, `install_windows_requirements` | Checks for, and installs, what Windows virtual machines need |

## macOS virtual machines

When you start a macOS virtual machine with the guest app enabled, Hypervisaur attaches a disk with the VirtualBuddyGuest app. Select the "Guest" disk in the Finder sidebar and open the app to install it. The guest app requires macOS 14 or later for clipboard sharing and automatic mounting of shared folders; on macOS 13, it only mounts shared folders.

To mount shared folders without the guest app, run this in the virtual machine's Terminal:

```bash
mkdir -p ~/Desktop/VirtualBuddyShared && mount -t virtiofs VirtualBuddyShared ~/Desktop/VirtualBuddyShared
```

Virtual machines are stored in `~/Library/Application Support/Hypervisaur`.

## Screenshots and recordings

While a virtual machine runs, the camera button in its window's toolbar saves a screenshot of its display, and the record button records its display and sound to a movie. They're saved where macOS saves screenshots, which is your desktop unless you've chosen somewhere else in the Screenshot app.

Hypervisaur needs permission to record the screen for recordings, and for screenshots of macOS and Linux virtual machines; macOS asks for it the first time. Screenshots of Windows virtual machines come straight from the virtual machine's display, at its full resolution.

## Clones

Choose Clone from a virtual machine's menu in the library to make a copy that can run at the same time as the original. The clone gets its own network address and, for macOS, its own serial number. On APFS, the clone's files share their storage with the original's until either of them changes, so a clone takes seconds to make and only uses the space of what's different about it. The clone doesn't depend on the original afterwards: you can delete either one.

Duplicate makes an exact copy instead, with the same identity, which is what a saved session needs to resume. A virtual machine with a saved session can't be cloned; resume it and shut it down first.

Things the operating system in a clone keeps from the original:

- Windows keeps its computer name. This doesn't matter for networking, since each Windows virtual machine has a network of its own, but you can rename it in Settings › System › About.
- Most Linux distributions keep their machine ID, which some DHCP servers use to give out addresses, so a clone can get the same IP address as the original. Give the clone a new one with `sudo rm /etc/machine-id && sudo systemd-machine-id-setup`, then restart it.

## Building

Hypervisaur builds with Xcode 26 or later.

1. In `VirtualBuddy/Config/Signing.xcconfig`, set `VB_BUNDLE_ID_PREFIX` to something of your own, such as `com.yourname.`
2. In `VirtualBuddy/Config/Security.xcconfig`, set `VB_DEVELOPMENT_TEAM` to your team ID
3. Choose your team under Signing & Capabilities for the VirtualBuddy and VirtualBuddyGuest targets
4. Build the `VirtualBuddy` scheme

The project's targets and modules keep VirtualBuddy's names so that changes from VirtualBuddy can still be merged.

To build a notarized installer package for release, run `Scripts/release.sh` with a Developer ID certificate, a Developer ID provisioning profile and an App Store Connect API key. The script describes what it needs.

## Acknowledgements

Hypervisaur stands on the work of [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) and its contributors, and on [QEMU](https://www.qemu.org), [swtpm](https://github.com/stefanberger/swtpm), [wimlib](https://wimlib.net), [UTM](https://github.com/utmapp/UTM), the [virtio-win drivers](https://github.com/virtio-win/kvm-guest-drivers-windows), [Homebrew](https://brew.sh) and the [USB ID Repository](http://www.linux-usb.org/usb-ids.html). See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for the licenses of the software that Hypervisaur includes or uses.

## License

Hypervisaur is available under the [BSD 2-Clause License](./LICENSE).
