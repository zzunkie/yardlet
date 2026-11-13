# The Linux host

On Linux, Yardlet runs without screens: `yardlet host` keeps a computer's tasks, runs the harness CLIs installed on it,
and serves its tasks to the Mac, Windows and phone apps over the remote protocol (docs/REMOTE_PROTOCOL.md), as a Mac
does in Settings › Remote. A server, a virtual machine or a computer that stays on runs the harnesses; the person works
with them from another device. There is no Linux app with screens.

It is the engine (docs/PLATFORM_PORTABILITY.md) with `Platform/Portable/` and `Platform/Linux/`, built on Linux as
the app target `NativeHarnessClient` and the product `yardlet`.

## Commands

```sh
yardlet host start [--name NAME]   # Run the host in the foreground until it is stopped.
yardlet host status [--json]       # Show the running host: its paths, devices and harnesses.
yardlet host pair [--no-wait]      # Show a link that pairs a device with this host.
yardlet host project add FOLDER    # Make FOLDER a project that devices can start tasks in.
yardlet host project list          # List the projects.
yardlet --version
```

`yardlet host start` runs until it is stopped: SIGTERM, Control-C, or SIGHUP when its terminal closes. A stop ends
the host as quitting ends the Mac app: the turns it cuts off are written down and continue at the next start, the
remote's connections close, and the harnesses end with what they started. A second `start` for the same account
refuses while one runs (the lock is `host.lock` in the data folder, which holds the running host's process ID). The
remote is on for as long as the host runs; the host exists to be reached.

The other commands reach the running host over its control socket, `host.sock` in the data folder: the same private
socket the Yardlet MCP server reaches the Mac app on (YardletAgentTools' `UnixSocketListener`), in a folder only the
person can open, with connections from another account dropped unread. `status` exits 3 when no host runs.

A device starts tasks in a project or as a chat, as it does on a Mac. A headless host has no folder picker, so
`yardlet host project add` names the folders that are projects.

## What it keeps

The data folder is `$XDG_DATA_HOME/yardlet`, else `~/.local/share/yardlet`, readable by the person alone (0700):

- the task index, transcripts, drafts, projects and schedules, as the Mac keeps them in `~/.yardlet`;
- `remote/`: the paired devices (`devices.json`), the audit log (`audit.log`) and the host's remote keys
  (`identity.json`, 0600), in the Mac's formats;
- `host.lock` and `host.sock`, while a host runs.

Its preferences are in `$XDG_CONFIG_HOME/yardlet.plist`, else `~/.config/yardlet.plist`, where Foundation on Linux keeps
a program's: written when the host stops, and every half minute while it runs.

The keys are in a file because a headless server usually has no keyring. The file is written whole through a
temporary file the owner alone may read (`RemoteFileIdentityStore`), and a key file that others could read is narrowed
to its owner before it is read.

## Processes

Foundation's `Process` on Linux starts each child in a process group of its own (`POSIX_SPAWN_SETPGROUP`) and its
`terminate()` signals the child alone (confirmed in swift-corelibs-foundation's source), so the node and MCP servers a
harness started would outlive it. `Platform/Linux/NativeProcessTree.swift` ends a task's process as the Mac's layer
does: it reads the process table in `/proc`, ends the descendants while the process is still their parent, then every
process left in its group, which also reaches those whose parent has already ended, and last the process itself, all
with SIGKILL. A descendant that both left the group and lost its parent first (a daemon that forked twice and called
`setsid`) is not found. Foundation closes every other descriptor in a child it starts, so a harness inherits none of
the host's sockets.

## Finding the harnesses

A systemd service starts with systemd's `PATH`, without the folders the person's shell profile adds (`~/.local/bin`
for Claude Code, npm's global folder, nvm's). As the Mac app does when the Dock opens it, the host asks the person's
login shell (the account's shell in the user database, else `$SHELL`) for its `PATH` once at start
(`Runtime/LoginShellPath.swift`, `-l -i`, at most five seconds) and starts harnesses with it; `status` answers once
that first look for the harnesses is done. Started from a terminal, it keeps that terminal's `PATH`.

## The relay

Foundation on Linux opens a WebSocket through libcurl only when it was built against libcurl 7.86 or later and the
system's libcurl was built with WebSocket support (curl 8.11 turned it on by default). The toolchain the host is built
with, Ubuntu 22.04's, was built against curl 7.81, so its `URLSessionWebSocketTask` never opens one, whatever the
system's libcurl. The host's relay socket (`YardletRemote/RemoteCurlWebSocket.swift`) asks libcurl only for the
connection (`CURLOPT_CONNECT_ONLY`: TCP, TLS checked against the system's certificates, a proxy the environment names),
which every libcurl gives, and speaks RFC 6455's handshake and frames on it itself, so the relay opens on every
distribution the host runs on.

## What it does not have yet

The direct-path listener: until it comes, a device reaches the host only through the relay. A QR code for pairing, a systemd service, the release tarballs and their installer, and harness sign-in from the
terminal are still to come.

## Where it is built

`.github/workflows/linux-host.yml` builds the host and its tests for x86_64 and aarch64 in swift.org's Ubuntu 22.04
image, pinned by digest, for every pull request that changes more than documents and for `main`. It runs the Linux
layer's tests (`Tests/YardletHostTests/`) in a home of their own, then `scripts/linux/check-host.sh`, which starts the
host as a person would, asks its status, adds a project, checks that a second host refuses to start and that SIGTERM
ends it, and lists what it left in its home. It is a check to read, not a required one.

```sh
swift build --product yardlet --force-resolved-versions
```
