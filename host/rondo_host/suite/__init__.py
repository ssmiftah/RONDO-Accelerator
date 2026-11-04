"""One test suite, three targets (spec 15.5): the same functions run through CocotbTransport (sim), the mock model, or SpidevTransport +
gpiod (FPGA / chip). Pass criteria are identical and bit-exact."""
from .cases import run_suite, Vectors, CASES  # noqa: F401
