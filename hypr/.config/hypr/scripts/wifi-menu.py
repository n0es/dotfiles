#!/usr/bin/env python3
"""Wi-Fi selector popup using GTK3 + gtk-layer-shell. Dismisses on outside click."""

import subprocess
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("GtkLayerShell", "0.1")
from gi.repository import Gtk, Gdk, GtkLayerShell, Pango

# -- Colors from STYLEGUIDE.md --
BG = "#0a0a0a"
SURFACE = "#141414"
FG = "#d4d4d4"
FG_MUTED = "#666666"
ACCENT = "#ffa032"
RED = "#cc4444"
GREEN = "#88bb88"

CSS = f"""
window {{
    background-color: {BG};
    border: 1px solid rgba(255,160,50,0.3);
    border-radius: 4px;
}}
.network-list {{
    background-color: transparent;
}}
.network-row {{
    padding: 6px 12px;
    border-radius: 4px;
    background-color: transparent;
}}
.network-row:hover {{
    background-color: rgba(255,160,50,0.15);
}}
.network-row:active {{
    background-color: rgba(255,160,50,0.25);
}}
.network-name {{
    color: {FG};
    font-family: "CaskaydiaCove Nerd Font";
    font-size: 13px;
}}
.network-icon {{
    color: {ACCENT};
    font-family: "CaskaydiaCove Nerd Font";
    font-size: 14px;
}}
.separator {{
    background-color: {FG_MUTED};
    min-height: 1px;
    margin: 4px 8px;
}}
.action-row {{
    padding: 6px 12px;
    border-radius: 4px;
}}
.action-row:hover {{
    background-color: rgba(255,160,50,0.15);
}}
.action-label {{
    color: {FG_MUTED};
    font-family: "CaskaydiaCove Nerd Font";
    font-size: 13px;
}}
.connected {{
    color: {GREEN};
}}
"""


def get_networks():
    result = subprocess.run(
        ["nmcli", "-t", "-f", "ssid,signal,security,active", "dev", "wifi", "list"],
        capture_output=True, text=True
    )
    seen = set()
    networks = []
    for line in result.stdout.strip().splitlines():
        parts = line.split(":")
        if len(parts) < 4 or not parts[0]:
            continue
        ssid = parts[0]
        if ssid in seen:
            continue
        seen.add(ssid)
        signal = int(parts[1]) if parts[1].isdigit() else 0
        secured = parts[2] not in ("", "--")
        active = parts[3] == "yes"
        if signal >= 75:
            icon = "󰤨"
        elif signal >= 50:
            icon = "󰤥"
        elif signal >= 25:
            icon = "󰤢"
        else:
            icon = "󰤟"
        networks.append({
            "ssid": ssid, "signal": signal, "secured": secured,
            "active": active, "icon": icon
        })
    networks.sort(key=lambda n: (-n["active"], -n["signal"]))
    return networks


def is_known(ssid):
    result = subprocess.run(
        ["nmcli", "-t", "-f", "name", "con", "show"],
        capture_output=True, text=True
    )
    return ssid in result.stdout.strip().splitlines()


def notify(msg):
    subprocess.Popen(["notify-send", "Wi-Fi", msg])


class WifiMenu(Gtk.Window):
    def __init__(self):
        super().__init__()

        # Apply CSS
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        # Layer shell setup
        GtkLayerShell.init_for_window(self)
        GtkLayerShell.set_layer(self, GtkLayerShell.Layer.OVERLAY)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.TOP, True)
        GtkLayerShell.set_anchor(self, GtkLayerShell.Edge.RIGHT, True)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.TOP, 34)
        GtkLayerShell.set_margin(self, GtkLayerShell.Edge.RIGHT, 8)
        GtkLayerShell.set_keyboard_mode(self, GtkLayerShell.KeyboardMode.ON_DEMAND)

        self.set_default_size(280, -1)

        # Close on focus loss
        self.connect("focus-out-event", lambda *_: self.quit())
        self.connect("key-press-event", self.on_key)

        # Build UI
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
        box.set_margin_top(6)
        box.set_margin_bottom(6)
        box.set_margin_start(6)
        box.set_margin_end(6)
        self.add(box)

        networks = get_networks()
        current = None

        for net in networks:
            row = self.make_network_row(net)
            box.pack_start(row, False, False, 0)
            if net["active"]:
                current = net["ssid"]

        # Separator + actions
        sep = Gtk.Separator()
        sep.get_style_context().add_class("separator")
        box.pack_start(sep, False, False, 2)

        if current:
            disconnect_btn = self.make_action_row(
                f"󰅙  Disconnect ({current})", self.on_disconnect
            )
            box.pack_start(disconnect_btn, False, False, 0)

        disable_btn = self.make_action_row("󰖪  Disable Wi-Fi", self.on_disable)
        box.pack_start(disable_btn, False, False, 0)

        self.show_all()

    def make_network_row(self, net):
        btn = Gtk.Button()
        btn.set_relief(Gtk.ReliefStyle.NONE)
        btn.get_style_context().add_class("network-row")

        hbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        btn.add(hbox)

        icon = Gtk.Label(label=net["icon"])
        icon.get_style_context().add_class("network-icon")
        if net["active"]:
            icon.get_style_context().add_class("connected")
        hbox.pack_start(icon, False, False, 0)

        lock = "󰌾 " if net["secured"] else ""
        name = Gtk.Label(label=f"{lock}{net['ssid']}")
        name.set_xalign(0)
        name.set_ellipsize(Pango.EllipsizeMode.END)
        name.get_style_context().add_class("network-name")
        if net["active"]:
            name.get_style_context().add_class("connected")
        hbox.pack_start(name, True, True, 0)

        btn.connect("clicked", lambda *_, s=net["ssid"]: self.on_connect(s))
        return btn

    def make_action_row(self, text, callback):
        btn = Gtk.Button()
        btn.set_relief(Gtk.ReliefStyle.NONE)
        btn.get_style_context().add_class("action-row")

        label = Gtk.Label(label=text)
        label.set_xalign(0)
        label.get_style_context().add_class("action-label")
        btn.add(label)

        btn.connect("clicked", lambda *_: callback())
        return btn

    def on_connect(self, ssid):
        self.hide()
        if is_known(ssid):
            r = subprocess.run(["nmcli", "con", "up", ssid], capture_output=True)
            if r.returncode == 0:
                notify(f"Connected to {ssid}")
            else:
                notify(f"Failed to connect to {ssid}")
        else:
            # Password dialog
            dialog = Gtk.Dialog(title=f"Password for {ssid}", parent=self)
            dialog.set_default_size(280, -1)
            entry = Gtk.Entry()
            entry.set_visibility(False)
            entry.set_placeholder_text("Password")
            entry.connect("activate", lambda *_: dialog.response(Gtk.ResponseType.OK))
            dialog.get_content_area().pack_start(entry, True, True, 8)
            dialog.add_buttons("Cancel", Gtk.ResponseType.CANCEL, "Connect", Gtk.ResponseType.OK)
            dialog.show_all()
            resp = dialog.run()
            pw = entry.get_text()
            dialog.destroy()
            if resp == Gtk.ResponseType.OK and pw:
                r = subprocess.run(
                    ["nmcli", "dev", "wifi", "connect", ssid, "password", pw],
                    capture_output=True
                )
                if r.returncode == 0:
                    notify(f"Connected to {ssid}")
                else:
                    notify(f"Failed to connect to {ssid}")
        self.quit()

    def on_disconnect(self):
        subprocess.run(["nmcli", "dev", "disconnect", "wlan0"], capture_output=True)
        notify("Disconnected")
        self.quit()

    def on_disable(self):
        subprocess.run(["nmcli", "radio", "wifi", "off"])
        notify("Wi-Fi disabled")
        self.quit()

    def on_key(self, widget, event):
        if event.keyval == Gdk.KEY_Escape:
            self.quit()

    def quit(self):
        Gtk.main_quit()


# Rescan in background for freshness
subprocess.Popen(["nmcli", "dev", "wifi", "rescan"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

win = WifiMenu()
Gtk.main()
