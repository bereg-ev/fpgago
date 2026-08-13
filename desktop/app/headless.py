"""app/headless.py — Qt-free serial transport for scripted board access.

The GUI talks to the MCU through SerialManager (Qt signals, auto-ping).
The library CLI needs the same BoardOps operations — upload, mount, run —
from a plain terminal, so this module provides the minimal transport
surface BoardOps and ConsoleSession expect, built on pyserial + the
threaded hostlink reader.  No PySide6 import anywhere on this path.

    with open_board() as ops:            # autodetects the fpgago port
        ops.fs_upload("c64-game.d64", data, progress=print)
        ops.run_game("c64-game.d64")
"""

from __future__ import annotations

import threading
from typing import Optional

from . import hostlink
from .board_backend import BoardOps

RPI_VID = 0x2E8A                 # Raspberry Pi (RP2040/RP2350) USB vendor id
BAUD = 115200


def autodetect() -> Optional[str]:
    """Device path of the most likely fpgago MCU port, or None."""
    import serial.tools.list_ports
    for p in serial.tools.list_ports.comports():
        if p.vid == RPI_VID:
            return p.device
    return None


class HeadlessLink:
    """SerialManager look-alike over bare pyserial: command(), write_bytes(),
    text taps for ConsoleSession.  No auto-ping timer, so hold_pings() has
    nothing to suppress and is a no-op."""

    def __init__(self, device: str):
        import serial
        self._ser = serial.Serial(device, BAUD, timeout=0.2)
        self.device = device
        self.P = hostlink.load_proto()
        self._tap_lock = threading.Lock()
        self._taps: list = []
        self._hl = hostlink.HostLink(
            read_fn=self._ser.read, write_fn=self._ser.write,
            proto=self.P, on_text=self._on_text)
        self._hl.start()

    def _on_text(self, data: bytes):
        with self._tap_lock:
            for q in self._taps:
                q.put(data)

    # -- the BoardOps / ConsoleSession transport surface ---------------------
    def command(self, cmd_type: int, payload: bytes = b"",
                timeout: float = 2.0):
        return self._hl.command(cmd_type, payload, timeout=timeout)

    def link_ping(self) -> dict:
        return self._hl.ping()

    def write_bytes(self, data: bytes):
        self._ser.write(data)

    def add_text_tap(self, q):
        with self._tap_lock:
            self._taps.append(q)

    def remove_text_tap(self, q):
        with self._tap_lock:
            if q in self._taps:
                self._taps.remove(q)

    def hold_pings(self):
        pass

    def release_pings(self):
        pass

    def close(self):
        self._hl.stop()
        try:
            self._ser.close()
        except Exception:                            # noqa: BLE001
            pass


class open_board:
    """Context manager: open (or autodetect) the board port, ping it, and
    yield ready-to-use BoardOps.  Raises IOError when no board answers."""

    def __init__(self, port: Optional[str] = None):
        self._port = port
        self._link: Optional[HeadlessLink] = None

    def __enter__(self) -> BoardOps:
        port = self._port or autodetect()
        if not port:
            raise IOError("no fpgago board found (no Raspberry Pi USB CDC "
                          "port); plug it in or pass --port")
        try:
            self._link = HeadlessLink(port)
        except OSError as e:
            if getattr(e, "errno", None) == 16 or "usy" in str(e):
                raise IOError(
                    f"{port} is busy — close the serial terminal / desktop "
                    "app (or the other session) holding it") from e
            raise
        try:
            self._link.link_ping()
        except Exception as e:
            self._link.close()
            raise IOError(f"board on {port} not answering hostlink PING: {e}"
                          ) from e
        return BoardOps(self._link)

    def __exit__(self, *exc):
        if self._link is not None:
            self._link.close()
        return False
