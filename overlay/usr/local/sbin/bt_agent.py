#!/usr/bin/env python3
"""Auto-accepting BlueZ pairing agent (NoInputNoOutput).

bluetoothctl's built-in agent disappears in non-interactive shells, which makes
BLE pairing fail with `new_auth() No agent available for request type 2`
(request type 2 = RequestConfirmation).  Run this in the background first, then
pair from another process.
"""
import sys
import dbus
import dbus.service
import dbus.mainloop.glib
from gi.repository import GLib

AGENT_PATH = "/k50/agent"


def log(msg):
    print(msg, flush=True)


class Agent(dbus.service.Object):
    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        log("Release")

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        log("AuthorizeService %s %s -> yes" % (device, uuid))

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        log("RequestPinCode %s -> 0000" % device)
        return "0000"

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def DisplayPinCode(self, device, pincode):
        log("DisplayPinCode %s %s" % (device, pincode))

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        log("RequestPasskey %s -> 0" % device)
        return dbus.UInt32(0)

    @dbus.service.method("org.bluez.Agent1", in_signature="ouq", out_signature="")
    def DisplayPasskey(self, device, passkey, entered):
        log("DisplayPasskey %s %06u %u" % (device, passkey, entered))

    @dbus.service.method("org.bluez.Agent1", in_signature="ou", out_signature="")
    def RequestConfirmation(self, device, passkey):
        # Accept unconditionally: this is a mouse, no MITM protection needed.
        log("RequestConfirmation %s %06u -> yes" % (device, passkey))

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        log("RequestAuthorization %s -> yes" % device)

    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Cancel(self):
        log("Cancel")


def main():
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    Agent(bus, AGENT_PATH)
    manager = dbus.Interface(
        bus.get_object("org.bluez", "/org/bluez"), "org.bluez.AgentManager1"
    )
    try:
        manager.UnregisterAgent(AGENT_PATH)
    except dbus.DBusException:
        pass
    manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    manager.RequestDefaultAgent(AGENT_PATH)
    log("agent registered at %s (NoInputNoOutput, default)" % AGENT_PATH)
    GLib.MainLoop().run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
