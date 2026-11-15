"""space-gui's light/dark preference: the host session's into the container.

  color-scheme.py host-watch   (as the host user, on their session bus)
  color-scheme.py portal       (in the container, on the run's private bus)

host-watch reads org.freedesktop.appearance color-scheme from the host
session's xdg-desktop-portal (Settings), prints `dark` or `light`, and
again on every SettingChanged of it. ./helper.py starts it as the host
user (never on the container's side) and writes each value it prints to
the run directory's `color-scheme` file (read-only in the container).
Dark is the fallback: no portal, no answer, or "no preference" (0).

portal is a minimal org.freedesktop.portal.Desktop on the run's private
D-Bus session bus, started by ./helper.py in front of the command
(`portal -- <command>`: the name is owned before the command starts, the
command runs as its child, its exit status is the portal's): only the
Settings interface, only org.freedesktop.appearance color-scheme, read from that
file (SPACE_GUI_COLOR_SCHEME_FILE; SPACE_GUI_COLOR_SCHEME, then dark,
while it is missing). A change of the file is announced as
SettingChanged, so apps that follow the portal (libadwaita, GTK 4, Qt 6)
follow the host live; Electron reads GTK's settings.ini at launch instead
(./helper.py writes one per run). No other portal
interface exists there, and nothing goes back to the host.
"""

import asyncio
import os
import sys

from dbus_fast import BusType, DBusError, Message, MessageType, Variant
from dbus_fast.aio import MessageBus
from dbus_fast.service import PropertyAccess, ServiceInterface, dbus_property, method, signal

NAME = "org.freedesktop.portal.Desktop"
PATH = "/org/freedesktop/portal/desktop"
IFACE = "org.freedesktop.portal.Settings"
NS, KEY = "org.freedesktop.appearance", "color-scheme"
VALUES = {"dark": 1, "light": 2}


def scheme(value: object) -> str:
    """The portal's value (1 dark, 2 light, 0 no preference) as a word;
    anything but light is dark."""
    while isinstance(value, Variant):
        value = value.value
    return "light" if value == 2 else "dark"


def log(msg: str) -> None:
    print(f"space-gui color-scheme: {msg}", file=sys.stderr, flush=True)


async def host_watch() -> int:
    try:
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
    except Exception as e:  # no session bus: the helper falls back to dark
        log(f"no session bus: {e}")
        return 1
    last: list[str] = []

    def emit(word: str) -> None:
        if last != [word]:
            last[:] = [word]
            print(word, flush=True)

    def on_message(msg: Message) -> None:
        if (msg.message_type == MessageType.SIGNAL and msg.interface == IFACE
                and msg.member == "SettingChanged" and msg.body[:2] == [NS, KEY]):
            emit(scheme(msg.body[2]))

    bus.add_message_handler(on_message)
    rule = (f"type='signal',sender='{NAME}',path='{PATH}',interface='{IFACE}',"
            f"member='SettingChanged',arg0='{NS}',arg1='{KEY}'")
    await bus.call(Message(destination="org.freedesktop.DBus", path="/org/freedesktop/DBus",
                           interface="org.freedesktop.DBus", member="AddMatch", signature="s", body=[rule]))
    reply = None
    for member in ("ReadOne", "Read"):  # ReadOne: portal >= 1.15; Read: older (variant in a variant)
        reply = await bus.call(Message(destination=NAME, path=PATH, interface=IFACE, member=member,
                                       signature="ss", body=[NS, KEY]))
        if reply.message_type == MessageType.METHOD_RETURN:
            break
    if reply is None or reply.message_type != MessageType.METHOD_RETURN:
        log(f"the host's portal gave no color-scheme: {reply.body if reply else None}")
        emit("dark")
    else:
        emit(scheme(reply.body[0]))
    await bus.wait_for_disconnect()
    return 0


class Settings(ServiceInterface):
    def __init__(self, value: int):
        super().__init__(IFACE)
        self.value = value

    @staticmethod
    def check(namespace: str, key: str) -> None:
        if (namespace, key) != (NS, KEY):
            raise DBusError("org.freedesktop.portal.Error.NotFound", "Requested setting not found")

    @method()
    def ReadAll(self, namespaces: "as") -> "a{sa{sv}}":  # noqa: F821
        def hit(p: str) -> bool:
            return p in ("", NS) or (p.endswith("*") and NS.startswith(p[:-1]))
        if not namespaces or any(hit(p) for p in namespaces):
            return {NS: {KEY: Variant("u", self.value)}}
        return {}

    @method()
    def Read(self, namespace: "s", key: "s") -> "v":  # noqa: F821
        self.check(namespace, key)
        # as xdg-desktop-portal answers it: the value in a further variant
        return Variant("v", Variant("u", self.value))

    @method()
    def ReadOne(self, namespace: "s", key: "s") -> "v":  # noqa: F821
        self.check(namespace, key)
        return Variant("u", self.value)

    @signal()
    def SettingChanged(self, namespace: str, key: str, value: Variant) -> "ssv":  # noqa: F821
        return [namespace, key, value]

    @dbus_property(access=PropertyAccess.READ)
    def version(self) -> "u":  # noqa: F821
        return 2


def read_file(path: str) -> str | None:
    try:
        word = open(path).read().strip()
    except OSError:
        return None
    return word if word in VALUES else None


async def portal(argv: list[str]) -> int:
    path = os.environ.get("SPACE_GUI_COLOR_SCHEME_FILE", "")
    initial = os.environ.get("SPACE_GUI_COLOR_SCHEME", "dark")
    word = read_file(path) or (initial if initial in VALUES else "dark")
    settings = Settings(VALUES[word])
    try:
        bus = await MessageBus(bus_type=BusType.SESSION).connect()
        bus.export(PATH, settings)
        # owned before the app starts: clients that look for an owner
        # rather than call find it
        await bus.request_name(NAME)
    except Exception as e:
        # never keep the app from starting: without the portal it still
        # has the launch-time value (env, settings.ini)
        log(f"no portal for the run: {e}")
        if argv:
            os.execvp(argv[0], argv)
        return 1

    async def follow() -> None:
        nonlocal word
        while True:
            await asyncio.sleep(1)
            new = read_file(path)
            if new and new != word:
                word = new
                settings.value = VALUES[word]
                settings.SettingChanged(NS, KEY, Variant("u", settings.value))

    task = asyncio.create_task(follow())
    if not argv:
        await bus.wait_for_disconnect()
        return 0
    app = await asyncio.create_subprocess_exec(*argv)
    rc = await app.wait()
    task.cancel()
    return rc if rc >= 0 else 128 - rc


if __name__ == "__main__":
    if len(sys.argv) == 2 and sys.argv[1] == "host-watch":
        sys.exit(asyncio.run(host_watch()))
    if len(sys.argv) >= 2 and sys.argv[1] == "portal":
        # portal [-- command args...]: serve, and run the command beside it
        rest = sys.argv[2:]
        if rest[:1] == ["--"]:
            rest = rest[1:]
        sys.exit(asyncio.run(portal(rest)))
    raise SystemExit("usage: color-scheme.py host-watch | portal [-- command args...]")
