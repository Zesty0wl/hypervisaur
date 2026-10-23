<p align="center">
  <img src="./assets/AppIcon/Hypervisaur-2048.png" width="160" alt="The Hypervisaur app icon, a T. rex head on a teal background">
</p>

<h1 align="center">Hypervisaur</h1>

<p align="center">Run macOS, Linux and Windows 11 virtual machines on Apple silicon Macs.</p>

## About this project

Hypervisaur is a fork of [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) by Guilherme Rambo. Almost everything that makes it work for macOS and Linux virtual machines is his work, and it keeps VirtualBuddy's BSD license and copyright notice. It's an independent project, not affiliated with or endorsed by VirtualBuddy, so please report problems with Hypervisaur here rather than to VirtualBuddy.

Hypervisaur adds Windows 11 virtual machines, running with QEMU, and a server that lets coding agents create and run virtual machines. Much of that was written with [Claude Code](https://claude.com/claude-code), Anthropic's coding agent, and reviewed and tested on real virtual machines. VirtualBuddy doesn't accept contributions written with AI tools, which is why these changes live in a fork instead.

## Features

- **macOS virtual machines** on macOS 12 or later, using Apple's Virtualization framework, with the macOS versions available to download built in
- **Linux virtual machines**, from the distributions in the built-in catalog or any ARM64 disc image
- **Windows 11 virtual machines**, installed from Microsoft's Windows 11 ARM64 disc image, optionally without going through Windows Setup at all
- Shared folders, clipboard sharing and saved sessions for macOS guests
- Importing virtual machines from VirtualBuddy and UTM
- An [MCP](https://modelcontextprotocol.io) server, so a coding agent can build a Windows virtual machine for you

## Requirements

- A Mac with Apple silicon
- macOS 14 or later
- For Windows virtual machines, [Homebrew](https://brew.sh) and the [Windows 11 ARM64 disc image](https://www.microsoft.com/software-download/windows11arm64) from Microsoft

## Installing

Download the latest release from the [Releases](../../releases) page, open the disk image and drag Hypervisaur to your Applications folder.

Hypervisaur doesn't update itself yet. Check the Releases page for new versions.

## Windows virtual machines

Choose Windows when creating a virtual machine. Hypervisaur first checks for what Windows needs on your Mac, and installs anything that's missing with a single click:

| Component | What it's for |
| --- | --- |
| [QEMU](https://www.qemu.org) | Runs Windows with the Hypervisor framework, using the UEFI firmware that comes with it |
| [swtpm](https://github.com/stefanberger/swtpm) | The TPM 2.0 that Windows 11 requires |
| [wimlib](https://wimlib.net) | Copies the Windows installer onto a disk that the virtual machine can start from quickly |
| Windows drivers | The virtio drivers for the network adapter, display and other devices, signed by Microsoft. They're downloaded from [UTM's guest tools](https://github.com/utmapp/qemu/releases) and checked against a known checksum |

QEMU, swtpm and wimlib come from Homebrew, which you need to install yourself. Then choose the Windows disc image and give the virtual machine a name. With **Set Up Windows Automatically**, Windows installs without asking anything and signs in to a local account with the name and optional password you choose. Without it, you go through Windows Setup as usual.

Installing takes about 10 minutes. Windows Setup uses a basic 800×600 display; afterwards, Windows uses the resolution in the virtual machine's display settings.

### Things to know

- You need your own Windows license. Windows is installed without a product key, so it isn't activated until you activate it.
- Windows virtual machines use NAT networking, sound output and a fixed display resolution that you can change in the virtual machine's settings. Shared folders, clipboard sharing, USB devices and saved sessions aren't available for Windows yet.
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
| `get_windows_requirements`, `install_windows_requirements` | Checks for, and installs, what Windows virtual machines need |

## macOS virtual machines

When you start a macOS virtual machine with the guest app enabled, Hypervisaur attaches a disk with the VirtualBuddyGuest app. Select the "Guest" disk in the Finder sidebar and open the app to install it. The guest app requires macOS 14 or later for clipboard sharing and automatic mounting of shared folders; on macOS 13, it only mounts shared folders.

To mount shared folders without the guest app, run this in the virtual machine's Terminal:

```bash
mkdir -p ~/Desktop/VirtualBuddyShared && mount -t virtiofs VirtualBuddyShared ~/Desktop/VirtualBuddyShared
```

Virtual machines are stored in `~/Library/Application Support/Hypervisaur`. Thanks to APFS, duplicating one in Finder takes almost no extra space, which is a quick way to keep a clean copy to go back to.

## Building

Hypervisaur builds with Xcode 26 or later.

1. In `VirtualBuddy/Config/Signing.xcconfig`, set `VB_BUNDLE_ID_PREFIX` to something of your own, such as `com.yourname.`
2. In `VirtualBuddy/Config/Security.xcconfig`, set `VB_DEVELOPMENT_TEAM` to your team ID
3. Choose your team under Signing & Capabilities for the VirtualBuddy and VirtualBuddyGuest targets
4. Build the `VirtualBuddy` scheme

The project's targets and modules keep VirtualBuddy's names so that changes from VirtualBuddy can still be merged.

## Acknowledgements

Hypervisaur stands on the work of [VirtualBuddy](https://github.com/insidegui/VirtualBuddy) and its contributors, and on [QEMU](https://www.qemu.org), [swtpm](https://github.com/stefanberger/swtpm), [wimlib](https://wimlib.net), [UTM](https://github.com/utmapp/UTM), the [virtio-win drivers](https://github.com/virtio-win/kvm-guest-drivers-windows), [Homebrew](https://brew.sh) and the [USB ID Repository](http://www.linux-usb.org/usb-ids.html). See [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) for the licenses of the software that Hypervisaur includes or uses.

## License

Hypervisaur is available under the [BSD 2-Clause License](./LICENSE).
