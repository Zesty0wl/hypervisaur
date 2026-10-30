# Hypervisaur agent protocol

Hypervisaur talks to the agent in a virtual machine over a channel of its own: a virtio serial port named `hypervisaur.agent` for Windows and Linux, and the guest app's connection for macOS. Linux and macOS agents also listen on virtio socket port 51781, which Hypervisaur moves to once it can connect to it, since Virtualization's console ports and the guest app's messages are far too slow for copying files. It goes back to the other link if the socket connection ends, and sends `reset` on whichever it moves to. Windows runs with QEMU, which has no virtio socket device on the Mac, so its agent only uses the serial port. Both sides exchange frames, which `VirtualWormhole/Source/GuestAgent/GuestAgentFrame.swift` implements for the Mac and for macOS guests, `WindowsGuestAgent/agent.c` for Windows, and `LinuxGuestAgent/hypervisaur-agent` for Linux.

## Frames

A frame is a 9-byte header followed by its payload. All numbers are little-endian.

| Bytes | Field |
| --- | --- |
| 4 | Payload length (`UInt32`), at most 1 MiB |
| 1 | Kind (`UInt8`) |
| 4 | Channel (`UInt32`) |

Frames of kinds a side doesn't know are skipped, so that either side can add kinds. A payload larger than 1 MiB means the other side doesn't speak this protocol, and the receiver discards what it has buffered.

Each program or transfer has a channel of its own, which the Mac chooses when it starts one. Channel 0 is for `reset` and `hello`.

## Version 1: programs

| Kind | Name | Direction | Payload |
| --- | --- | --- | --- |
| `0x01` | reset | to agent | Empty. Sent when the Mac connects. The agent stops everything it was doing for an earlier connection, including transfers, and replies with `hello`. |
| `0x02` | open | to agent | Starts a program: a byte of flags (bit 0: runs in a terminal), terminal columns and rows (`UInt16` each), then the command in UTF-8. |
| `0x03` | input | to agent | Input for the program. |
| `0x04` | inputEnd | to agent | Closes the program's input. |
| `0x05` | resize | to agent | Terminal columns and rows (`UInt16` each). |
| `0x06` | terminate | to agent | Stops the program, or cancels a transfer. |
| `0x41` | hello | from agent | Protocol version (`UInt32`), then a description of the system in UTF-8. Sent on channel 0 when the agent starts and after `reset`. |
| `0x42` | output | from agent | Output from the program. |
| `0x43` | errorOutput | from agent | Error output from the program. |
| `0x44` | exited | from agent | Exit status (`Int32`). The last frame on the channel. |
| `0x45` | failed | from agent | A description in UTF-8 of why the program or transfer couldn't start or didn't finish. The last frame on the channel. |

## Version 2: files and drags

Agents that report protocol version 2 or later in `hello` support these frames. The Mac only uses them with such agents.

| Kind | Name | Direction | Payload |
| --- | --- | --- | --- |
| `0x07` | putFiles | to agent | Starts receiving files into the guest on a new channel: a destination (`UInt8`), where 0 is the desktop of the user signed in at the guest's display. |
| `0x08` | fileHeader | both | Starts an item: its type (`UInt8`, 0 for a file, 1 for a folder), size in bytes (`UInt64`, 0 for folders), POSIX permissions (`UInt32`, 0 when unknown), modification date in seconds since 1970 (`Int64`, 0 when unknown), then its path relative to the transfer in UTF-8, with `/` between components. |
| `0x09` | fileData | both | The next bytes of the current file, at most 1 MiB at a time. Senders use 256 KiB. |
| `0x0A` | filesEnd | both | Empty. There are no more items. |
| `0x0B` | getFiles | to agent | Starts sending files from the guest on a new channel: the absolute paths of the files and folders to send, in UTF-8, one per line (separated by `\n`). |
| `0x0C` | acknowledge | both | How many bytes of file data the receiver has written so far on the channel (`UInt64`). |
| `0x0D` | catchDrag | to agent | Empty. Asks the agent to find out which files are being dragged in the guest. See [Dragging out of the guest](#dragging-out-of-the-guest). |
| `0x0E` | transferSize | both | The total size of the files in a transfer in bytes (`UInt64`), then the number of items (`UInt32`). Sent once, before the first `fileHeader`. |
| `0x46` | transferred | from agent | Where a `putFiles` transfer's items were put in the guest: their absolute paths in UTF-8, one per line. The last frame on the channel. |
| `0x47` | dragItems | from agent | The files being dragged in the guest: one line per item, with `f` for a file or `d` for a folder, a tab, and the item's absolute path, in UTF-8. Empty when nothing with files was dragged. The last frame on the channel. |

### Items

Items are sent in an order where a folder comes before what's in it. Each item's path is relative to the transfer, so the items of a transfer of `~/Documents/Report.pdf` and `~/Pictures/Holiday` might be `Report.pdf`, `Holiday`, `Holiday/1.jpg` and `Holiday/2.jpg`. A receiver rejects a transfer, replying `failed` or failing it on the Mac, if a path is absolute, has an empty, `.` or `..` component, or would put an item inside an item that isn't a folder. A file's `fileData` frames add up to exactly the size in its header, and the next `fileHeader` or `filesEnd` follows them.

Symbolic links aren't sent. Each side reports the permissions and modification date it knows, and the receiver applies them where its file system can.

### Flow control

The receiver of file data sends `acknowledge` as it writes it, at least every 1 MiB and after the last file. The sender has at most 4 MiB of file data that hasn't been acknowledged. This keeps the memory either side uses small, however fast the other side writes, and the acknowledgements are what the Mac shows as progress.

### Putting files in the guest

1. The Mac sends `putFiles`, `transferSize`, then each item's `fileHeader` and `fileData`, then `filesEnd`.
2. The agent writes the items into a new hidden folder inside the destination (on Windows, with the hidden attribute), so that partly written files are never seen. Writing them inside the destination means they get its permissions.
3. After `filesEnd`, the agent moves each top-level item from the hidden folder into the destination, removes the hidden folder, and replies `transferred` with the items' new paths. If an item with the same name is there already, it uses a new name: `Name 2.ext` on macOS, and `Name (2).ext` on Windows and Linux.
4. On Windows, characters that aren't allowed in names (`<>:"\|?*` and control characters) become `_`, and trailing dots and spaces are removed. On Linux, the items belong to the user they're put in the desktop of.

If anything fails, or the Mac sends `terminate`, the agent removes the hidden folder with everything in it and replies `failed`. `failed` after `terminate` says "Cancelled.".

The desktop is the one of the user signed in at the guest's display: on Windows, the user of the active console session, and on Linux, the user of the active graphical session on seat0. The agent replies `failed` if nobody is signed in.

On Linux, the desktop is the folder that the user's `~/.config/user-dirs.dirs` names, or `~/Desktop`, and it must be inside their home folder. See version 5 for how the agent, which runs as root, works there.

### Getting files from the guest

1. The Mac sends `getFiles` with the paths.
2. The agent replies `transferSize`, then each item's `fileHeader` and `fileData`, then `filesEnd`, with each path's last component as its top-level item. It sends nothing else on the channel afterwards.
3. The Mac acknowledges the data as it writes it. `terminate` stops the agent sending, without a reply.

### Dragging out of the guest

When the pointer leaves a virtual machine's window while its button is held, something may be being dragged in the guest. The Mac asks the agent with `catchDrag`:

1. The agent shows a small, nearly transparent window that accepts drops of files, centred on the guest's pointer and above other windows, in the desktop session of the user signed in at the display. On Windows, the agent runs as a service, so it starts a helper in that session to do this.
2. The Mac moves the guest's pointer a little so that the drag enters the window.
3. When a drag with files enters the window, the agent replies `dragItems` with them. If none does within 3 seconds, it replies `dragItems` with an empty payload and removes the window.
4. The Mac then releases the guest's mouse button, which drops the drag on the window. The window refuses the drop, so the drag ends without changing anything in the guest, and the agent removes the window.
5. The Mac starts a drag of the items on the Mac. When they're dropped, it copies them with `getFiles`.

The agent replies `failed` if it can't catch drags, such as on Linux, or if nobody is signed in.

## Version 3: the Linux socket

Version 3 only changes how Linux agents are reached: they listen on virtio socket port 51781 as well as the console port. Hypervisaur updates Linux agents that report an earlier version through the agent itself, so that they don't have to be installed again from the disc. The frames are the same as version 2. The macOS agent listens on the socket from the guest app that comes with Hypervisaur 0.3, and still reports version 2.

## Version 4: shared folders in Windows

Windows agents report version 4. QEMU on the Mac has no virtiofs device, so Hypervisaur shares a Windows virtual machine's folders over SMB instead: QEMU's user networking starts Samba from Homebrew for each connection that Windows makes to port 445 of `10.0.2.4`, so only the virtual machine can reach it. Each folder is a share of its own, named after the folder, so that each can be read-only. Windows 11 doesn't connect to shares as a guest, so the shares have a user named `hypervisaur`, with a password that's kept in the virtual machine's bundle. `WindowsFolderSharing` sets Samba up, and the agent connects Windows to the shares.

| Kind | Name | Direction | Payload |
| --- | --- | --- | --- |
| `0x0F` | shareFolders | to agent | Sent on channel 0 after each `hello`. The server's address, then, when something is shared, the user name, the password and the name of each share, in UTF-8, one per line. Only the address when nothing is shared. There's no reply. |

Drives belong to the session of the user who connected them, so the agent starts itself as `HypervisaurAgent.exe mapshares` in the session of each user who's signed in, with their token, and passes the payload on its input. It does it again when someone signs in. The helper:

1. Saves the user name and password in the user's credentials for the server, so that Windows can sign in again by itself, such as after a saved session is restored.
2. Disconnects drives for shares on the server that aren't in the list.
3. Connects each share that isn't connected yet to the last free drive letter, from Z: down, in the order of the list. While the network is still starting, it tries again every 2 seconds, 20 times. The drives aren't remembered, since the agent connects them at each sign-in, and Windows would otherwise complain at sign-in when they can't be reached.

When nothing is shared, it disconnects every drive for the server and removes the saved credentials.

## Version 5: Linux file delivery

Version 5 only changes how Linux agents put files in the guest, and the frames are the same as version 3. The agent runs as root, but the user whose desktop it puts files on can change anything in their home folder, including while a transfer is going, so the agent never uses a path there:

1. It opens each folder from the one it's in without following symbolic links, starting from the user's home folder, and creates, changes, moves and removes everything through those descriptors. A desktop that `user-dirs.dirs` puts outside the home folder isn't used, and a symbolic link anywhere on the way to the desktop, or in the transfer, makes the transfer fail.
2. The hidden folder belongs to root and only root can open it, so the user can't change what's in it until the items are moved onto the desktop. The items in it belong to the user.
3. `user-dirs.dirs` is only read if it's a regular file, and without waiting, so that a named pipe in its place can't stop the agent.

Linux agents report version 5, so Hypervisaur updates agents that report an earlier version through the agent itself. They ignore `shareFolders`, which Hypervisaur only sends to Windows.
