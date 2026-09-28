# IP config for Omarchy

A small [Omarchy](https://omarchy.org) shell plugin for flipping network adapters between DHCP and a static IP, and for turning them off and on. It looks and behaves like the Omarchy menu, and every action works from the keyboard or with the mouse.

![IP config demo](assets/demo.gif)

## Features

- **One row per adapter** (Wi-Fi and Ethernet). Each row shows the network name, and under it the adapter name, the IP address and the remaining DHCP lease time. The lease time reads `11h` or `3d`, and `exp.` if the lease has run out. If there's no address, the row shows the state instead: Off, No cable or Connecting….
- **DHCP and Static buttons** on each row. The active mode is highlighted. It switches the moment you choose it, without waiting for NetworkManager.
- **Static IP in one line:** `10.0.0.50/24 10.0.0.1 1.1.1.1`. A missing mask means `/24`, and if you leave out DNS the gateway is used. The field only accepts digits, dots, `/` and spaces.
- **Remembers your old static IP.** Switching to DHCP saves the static settings on the NetworkManager profile, whether this plugin or another tool set them. Opening Static later fills them back in.
- **Live DHCP progress** under each adapter while it connects, including connections NetworkManager starts on its own, like plugging in a cable. See [DHCP progress](#dhcp-progress).
- **Adapters work independently.** While one adapter waits on DHCP, you can still use the others.

## Requirements

- Omarchy with the Quickshell-based `omarchy-shell`
- NetworkManager (`nmcli`)
- `gdbus` (from glib2), to read saved static settings
- `python-gobject` with libnm's GObject bindings, to save static settings on the profile
- `notify-send`, for error notifications

These all come with a standard Omarchy install.

## Install

```sh
omarchy plugin add https://github.com/fivefold3/omarchy-ip-config --enable
```

Then bind a key in `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + N", "IP config", "omarchy-shell shell toggle io.github.fivefold3.ip-config")
```

If `SUPER + N` is already taken on your setup, call `hl.unbind("SUPER + N")` first, or pick another key.

## Uninstall

```sh
omarchy plugin remove io.github.fivefold3.ip-config
```

Then delete the `o.bind(...)` line from `~/.config/hypr/bindings.lua`.

If you turned on DHCP packet logging, turn it off again:

```sh
sudo rm /etc/NetworkManager/conf.d/90-ip-config-dhcp-log.conf
sudo nmcli general logging level INFO domains DEFAULT
```

Saved static settings stay on your NetworkManager profiles under the `ip-config.static-ipv4` key. They're harmless, and other tools ignore them.

## Keys

In the list:

| Key | Action |
|---|---|
| `Enter` / `Space` / click | Turn the adapter off or on |
| `→` / `l` / Static button | Open the static IP prompt |
| `←` / `h` / DHCP button | Switch to DHCP |
| `↑` `↓` / `j` `k` | Move between adapters |
| `Esc` | Close |

In the static IP prompt:

| Key | Action |
|---|---|
| `Enter` | Apply |
| `←` `→` / `h` `l` | Move the cursor |
| `←` / `h` at the start, or `Esc` | Back to the list |

The prompt opens with the adapter's current static settings, or the ones saved when it last switched to DHCP. Holding `←` walks the cursor to the start without leaving the prompt.

**Turning an adapter off:** for Wi-Fi this switches the radio off, the same as the Wi-Fi toggle in the bar. For Ethernet it disconnects the device through NetworkManager, and it stays down until you turn it back on. Ethernet with no cable has nothing to disconnect, so it can't be toggled. Its DHCP and Static settings can still be changed, and they apply when you plug in. None of this needs root.

## DHCP progress

While the menu is open, it follows NetworkManager's journal and shows DHCP progress in place of the adapter's address. That covers switches made here and connections NetworkManager starts on its own, like plugging in a cable or reconnecting. DHCP steps are often only milliseconds apart, so each one stays on screen for at least 0.6 s. When they're done, the row goes back to the address and lease time.

Out of the box you get the connection stages, e.g. `Releasing old address…`, `Starting DHCP…` and `Checking for conflicts…`.

**Optional: every packet.** NetworkManager only logs the individual DHCP packets (Discover, Offer, Request, Ack) at debug level. Changing that needs root, so the plugin never does it for you. To turn it on, run this once:

```sh
~/.config/omarchy/plugins/io.github.fivefold3.ip-config/ip-config setup-logging
```

That asks for your password, installs `extras/90-ip-config-dhcp-log.conf` into `/etc/NetworkManager/conf.d/`, and applies it immediately. It raises logging only for the DHCP part of NetworkManager. When renewing an address it already had, the client skips Discover and Offer, so you'll see only Request and Ack.

Reading the journal needs membership of `wheel` or `systemd-journal`, which Omarchy users normally have. Without it, the menu shows only the stages NetworkManager reports directly, such as `Releasing old address…` and `Checking address…`.

## How it works

- `IpConfig.qml` is the UI.
- `ip-config` is a Bash script that does all the NetworkManager work. It runs on its own too:

```sh
ip-config list                  # TSV: device type enabled connection method address state lease-expiry
ip-config toggle eth0
ip-config static eth0 "10.0.0.50/24 10.0.0.1 1.1.1.1"
ip-config dhcp eth0
ip-config prefill eth0          # what the static prompt would open with
ip-config watch                 # DHCP progress for all adapters, as it happens
ip-config setup-logging         # optional, see above
```

`static` and `dhcp` report their stages as `status<TAB>text` lines while the connection comes back up. `watch` reports DHCP steps as `event<TAB>device<TAB>text` lines, where empty text means the lease is done.

Saved static settings are stored on the NetworkManager profile under the `ip-config.static-ipv4` key. They're read over D-Bus and written through libnm, since `nmcli` can't write a profile's user data.

## Re-recording the demo

`demo/mock-backend` has the same interface as `ip-config`, but it keeps fake adapters in a scratch file, so recording never touches real networking. `demo/record.sh` drives the plugin on an empty workspace with `wtype` and records it with `gpu-screen-recorder`. `demo/make-gif.sh` crops the recording and converts it:

```sh
demo/record.sh /tmp/demo.mp4
demo/make-gif.sh /tmp/demo.mp4
```

## License

MIT
