"""Transports: one call = one SPI chip-select frame (spec 14.4)."""
import os


class Transport:
    """xfer(tx) -> rx of the same length (full duplex, one CS frame)."""
    max_hz = None

    def xfer(self, tx):
        raise NotImplementedError

    def set_speed(self, hz):
        """request a new SCLK (the largest supported rate <= hz); returns the rate actually used"""
        return hz

    @property
    def speed(self):
        return getattr(self, "_hz", None)

    def close(self):
        pass


class SpidevTransport(Transport):
    """Raspberry Pi 5 SPI0 through /dev/spidev0.0 (spidev, mode 0, 8 bit). Splitting into <= bufsiz frames is the caller's
    job (protocol.split_burst); bufsiz is read from /sys/module/spidev/parameters/bufsiz when available."""

    def __init__(self, bus=0, dev=0, hz=5_000_000):
        import spidev                                  # imported lazily: not available on a PC
        self._spi = spidev.SpiDev()
        self._spi.open(bus, dev)
        self._spi.mode = 0
        self._spi.bits_per_word = 8
        self._spi.lsbfirst = False
        self._spi.cshigh = False
        self._spi.max_speed_hz = int(hz)
        self._hz = self._spi.max_speed_hz
        try:
            with open("/sys/module/spidev/parameters/bufsiz") as fh:
                self.bufsiz = int(fh.read().strip())
        except OSError:
            self.bufsiz = 4096

    def xfer(self, tx):
        return bytes(self._spi.xfer3(list(tx)))        # xfer3: no 4096-byte split by the library, keeps one CS frame

    def set_speed(self, hz):
        self._spi.max_speed_hz = int(hz)
        self._hz = self._spi.max_speed_hz
        return self._hz

    def close(self):
        self._spi.close()


class MockTransport(Transport):
    """Calls a RondoModel directly (byte-accurate frames)."""

    def __init__(self, model, hz=5_000_000):
        self.model = model
        self._hz = hz

    def xfer(self, tx):
        return self.model.xfer(bytes(tx), self._hz)

    def set_speed(self, hz):
        self._hz = hz
        return hz
