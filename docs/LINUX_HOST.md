# The Linux host

On Linux, Yardlet runs without screens: `yardlet host` keeps a computer's tasks, runs the harness CLIs installed on it,
and serves its tasks to the Mac, Windows and phone apps over the remote protocol (docs/REMOTE_PROTOCOL.md), as a Mac
does in Settings › Remote. A server, a virtual machine or a computer that stays on runs the harnesses; the person works
with them from another device. There is no Linux app with screens.

It is the engine (docs/PLATFORM_PORTABILITY.md) with `Platform/Portable/` and `Platform/Linux/`, built on Linux as
the app target `NativeHarnessClient` and the product `yardlet`.

## Installing

```sh
curl -fsSL https://github.com/zzunkie/yardlet/releases/latest/download/yardlet-host-install.sh | sh
yardlet host service install
yardlet host pair
```

The installer (`scripts/linux/install.sh`, carried by a release as `yardlet-host-install.sh`) installs for the person's
own account, without root: the program in `~/.local/lib/yardlet` and the command at `~/.local/bin/yardlet`. It checks
that the computer can run the host (Linux on x86_64 or aarch64, glibc 2.35 or later, libcurl and SQLite, and it names
the package to install when one is missing), downloads `yardlet-host-linux-ARCH.tar.gz` and its `.sha256` from the
latest release, checks the package against it, and puts the program in place of one installed before it in one
rename. `YARDLET_HOST_DOWNLOAD` names another place to download from.

The package (`scripts/linux/package-host.sh`) is `yardlet` with the Swift runtime linked in (`--static-swift-stdlib`),
built on Ubuntu 22.04 so it runs on that glibc or a later one, with its resources, its version (`YardletVersion`) and the
relay a public build carries (`YardletRelayURL`) beside it. It needs glibc, libcurl and SQLite from the system. The
harnesses are the person's own installs, found as below; the host installs none.

## Keeping it running

`yardlet host service install [--name NAME] [--every-address]` writes a systemd user unit,
`~/.config/systemd/user/yardlet-host.service`, that runs `yardlet host start` with those options, enables it and starts
it now; systemd starts it again at every boot and after a failure, and its output is in
`journalctl --user -u yardlet-host.service`. Stopping it ends the harnesses with the unit's processes
(`KillMode=control-group`). Without linger, systemd stops a person's services when they log out, so `install` turns
linger on when it is off (`loginctl enable-linger`) and writes in the unit that it did (`X-YardletEnabledLinger=yes`, a
key systemd ignores); where turning it on needs an administrator, it says to run `sudo loginctl enable-linger USER`.
A host already running in a terminal must be stopped first.

`yardlet host service uninstall` stops the service, disables it and removes the unit, turns linger off only when the
unit says Yardlet turned it on, and lists what stays:

- the data folder (below): the tasks, transcripts, projects and the remote's keys and paired devices;
- the program, `~/.local/lib/yardlet` and `~/.local/bin/yardlet`, which removing uninstalls the host;
- the preferences, `~/.config/yardlet.plist`;
- each harness's own sign-in and history (`~/.claude`, `~/.codex` and the like), which belong to the harness.

Nothing else is written outside these: no system file, no package and no change to the shell's profile.

## Updating

`yardlet host update` downloads the latest release's installer and runs it, as installing did: when the release's
package is the one installed (the same SHA-256, kept in `~/.local/lib/yardlet/.package-sha256`) it says the host is up
to date and changes nothing; otherwise it puts the new program in place and restarts the service when it runs. The
installer and the package come from GitHub Releases over HTTPS, the package checked against the SHA-256 the release
lists beside it. The package is not signed yet, so that check is as strong as the release's own download.

## Commands

```sh
yardlet host start [--name NAME] [--every-address]
                                   # Run the host in the foreground until it is stopped.
yardlet host status [--json]       # Show the running host: its paths, devices and harnesses.
yardlet host pair [--no-wait]      # Show a QR code and a link that pair a device with this host.
yardlet host project add FOLDER    # Make FOLDER a project that devices can start tasks in.
yardlet host project list          # List the projects.
yardlet host service install [--name NAME] [--every-address]
                                   # Run the host as a systemd user service, now and at every boot.
yardlet host service uninstall     # Stop and remove the service, and list what stays.
yardlet host update                # Install the latest release's host, as installing did.
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

`--name` is the name devices see, the computer's host name by default.

`yardlet host pair` opens a pairing for five minutes, as Settings › Remote's Pair does on a Mac, and prints its QR
code (half blocks, black on white whatever the terminal's colours) and its link; it waits until a device pairs or the
pairing ends, and Control-C closes it. Output to a file or a pipe gets the link alone, and `--no-wait` leaves the
pairing open without waiting. The Yardlet app on a phone scans the code; the Mac and Windows apps pair from the link
(Connect to a Mac).

A device starts tasks in a project or as a chat, as it does on a Mac. A headless host has no folder picker, so
`yardlet host project add` names the folders that are projects.

A Mac connected to the host opens its Settings as it opens another Mac's (docs/REMOTE_PROTOCOL.md, `hostSettings`):
the General, Instructions and Usage sections, whose changes the host keeps, as the Mac's remote host settings do. How
the host listens, its name and its relay are its own command's options, not settings a device changes.

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

## Direct paths

The host's listener (`RemoteLinuxListener` in YardletRemote) is shaped as the Windows app's `RemoteWinsockListener`:
BSD sockets served by one thread with `poll`, the WebSocket spoken by `RemoteWebSocket` with the same rules (an
opening request read up to 8 KB and answered only for a WebSocket upgrade without Origin, so a web page cannot reach
it), and every connection a `RemoteSecureConnection` that serves nothing before its Noise IK handshake with a paired
key, as on the Mac and Windows. Port 47616, or a free one when that is taken; there is no DNS-SD advertisement, and a
device reaches the host at the addresses its pairing link names.

A server often holds a public address, so by default the host listens on loopback, the same network's private IPv4
addresses (RFC 1918) and Tailscale's (100.64.0.0/10, fd7a:115c:a1e0::/48) alone, one socket for each. It follows the
interfaces through a netlink socket: a Tailscale that comes up after the host is reached at once, and a socket whose
address is gone closes. With `--every-address`, which the person chooses, it listens on every address and also names
the public ones to devices, after the private and Tailscale ones. Its sockets close when a program starts
(`SOCK_CLOEXEC`).

## The relay

Foundation on Linux opens a WebSocket through libcurl only when it was built against libcurl 7.86 or later and the
system's libcurl was built with WebSocket support (curl 8.11 turned it on by default). The toolchain the host is built
with, Ubuntu 22.04's, was built against curl 7.81, so its `URLSessionWebSocketTask` never opens one, whatever the
system's libcurl. The host's relay socket (`YardletRemote/RemoteCurlWebSocket.swift`) asks libcurl only for the
connection (`CURLOPT_CONNECT_ONLY`: TCP, TLS checked against the system's certificates, a proxy the environment names),
which every libcurl gives, and speaks RFC 6455's handshake and frames on it itself, so the relay opens on every
distribution the host runs on.

## What it does not have yet

Harness sign-in from the terminal is still to come. As on Windows, there is no Yardlet MCP server (so no connectors or session tools), terminal panel, browser panel or
vault.

## Where it is built

`.github/workflows/linux-host.yml` builds the host and its tests for x86_64 and aarch64 in swift.org's Ubuntu 22.04
image, pinned by digest, for every pull request that changes more than documents and for `main`. It runs the Linux
layer's tests (`Tests/YardletHostTests/`) in a home of their own, then `scripts/linux/check-host.sh`, which starts the
host as a person would, asks its status, adds a project, checks that a second host refuses to start and that SIGTERM
ends it, and lists what it left in its home. `scripts/linux/check-remote.sh` then checks the direct path: the host
listens on loopback and the runner's private address and not on every address, a browser's handshake gets 400, the
pairing QR code reads back as its link (zbar), and the fixture's phone (`yardlet-remote-fixture --pair LINK --new-chat
kimi-code`) pairs, starts a chat on the Windows checks' stand-in harness through the host, allows its request and gets
its answer; stopping the host ends the stand-in and the process it detached, and with `--every-address` the host
listens on every address.

The same workflow packs the release for both architectures as run artifacts (it makes no release and no tag) and
checks them. On an Ubuntu runner, whose systemd is real, `scripts/linux/check-install.sh` installs from a served copy
of the release, installs the service, which finds the stand-in harness on a `PATH` only the login shell's profile
sets, pairs a phone that chats with it, updates to a newer package (the service restarts on it, and a second update
says it is up to date), and uninstalls, which leaves linger on as it found it. `scripts/linux/check-distribution.sh`
runs the package in the containers of the distributions below, on the runner's network, and tries the relay with each
one's libcurl against the relay run locally (`relay/`, `wrangler dev`), as `ws://` and as `wss://` through a TLS proxy
whose certificate a CA made for the run signed (`scripts/linux/tls-proxy.py`): the fixture host opens its room and the
fixture's phone pairs through it and gets an answer, and before the system trusts that CA the `wss://` room does not
open. These are checks to read, not required ones.

```sh
swift build --product yardlet --force-resolved-versions
```

## Distributions

What the checks above found, for the package built on Ubuntu 22.04:

| Distribution | glibc | libcurl | The host | The relay (ws) | The relay (wss) |
| --- | --- | --- | --- | --- | --- |
