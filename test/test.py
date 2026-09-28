import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles, with_timeout

CLK_NS = 20            # 50 MHz
GATES = os.getenv("GATES") == "yes"

# which firmware image this sim run loaded (via +HEX=... plusarg)
HEX = cocotb.plusargs.get("HEX", "")


async def uart_rx(dut, chars, timeout_ns=60_000_000):
    """Record uo_out[0] edges; decode frames afterwards. Bit width is the
    minimum observed pulse width (a 'start bit' may merge with leading zero
    data bits, so it cannot be measured from a single pulse)."""
    tx = dut.uo_out
    edges = chars  # reuse the list: [(t_ns, level), ...]
    t = 0
    prev = 0
    armed = False  # ignore edges until the line has gone idle-high once
    while t < timeout_ns:
        await Timer(200, unit="ns")
        t += 200
        try:
            v = int(tx.value[0])
        except ValueError:
            v = prev
        if not armed:
            if v == 1:
                armed = True
            prev = v
            continue
        if v != prev:
            edges.append((t, v))
            prev = v


def uart_decode(edges):
    """Decode 8N1 frames from a (time, level) edge list."""
    if not edges:
        return b""
    widths = sorted({b - a for (a, _), (b, _) in zip(edges, edges[1:]) if b - a >= 400})
    if not widths:
        return b""
    n = len(edges)

    def level_at(time):
        lvl = 1
        for (te, le) in edges:
            if te <= time:
                lvl = le
            else:
                break
        return lvl

    bit = widths[0]
    out = bytearray()
    i = 0
    while i < n:
        # a falling edge after idle = start bit
        t0, v = edges[i]
        if v != 0:
            i += 1
            continue
        byte = 0
        for b in range(8):
            if level_at(t0 + int(bit * (b + 1.5))):
                byte |= 1 << b
        if level_at(t0 + int(bit * 9.5)) == 1:  # stop bit
            out.append(byte)
        # skip edges inside this frame (~10 bit cells)
        t_end = t0 + int(bit * 10)
        while i < n and edges[i][0] < t_end:
            i += 1
    return bytes(out)


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0x00   # GPIO in
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 20)
    dut.rst_n.value = 1


async def wait_tohost(dut, timeout_ns=200_000_000):
    try:
        await with_timeout(RisingEdge(dut.tohost_flag), timeout_ns, "ns")
    except Exception:
        return None
    return int(dut.tohost_val.value)


async def run_program(dut, name, expect_uart=b"", timeout_ns=200_000_000):
    edges = []
    rx = cocotb.start_soon(uart_rx(dut, edges))
    await reset(dut)
    val = await wait_tohost(dut, timeout_ns)
    rx.kill()
    if os.getenv("UART_DEBUG"):
        print("EDGES", edges)
    chars = uart_decode(edges)
    assert val is not None, f"{name}: no tohost write (uart={chars!r})"
    assert int(dut.psram_error.value) == 0, f"{name}: PSRAM protocol error"
    assert int(dut.flash_error.value) == 0, f"{name}: flash protocol error"
    assert val == 1, f"{name}: tohost={val:#x} (uart={chars!r})"
    if expect_uart:
        assert expect_uart in chars, \
            f"{name}: expected {expect_uart!r} in uart output {chars!r}"


@cocotb.test(skip="hello" not in HEX)   # also runs under GATES=yes
async def test_hello(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "hello", expect_uart=b"Hello RV32I\n")


@cocotb.test(skip=GATES or "memtest" not in HEX)
async def test_memtest(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "memtest", expect_uart=b"memtest done\n")


@cocotb.test(skip=GATES or "rftest" not in HEX)
async def test_rftest(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "rftest", expect_uart=b"rftest done\n")


@cocotb.test(skip=GATES or "flashtest" not in HEX)
async def test_flashtest(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "flashtest", expect_uart=b"flashtest done\n")
    # 6 WEN=1 window stores in main.c: 1 erase + 2 sw + 1 sh + 2 sb;
    # each must reach the flash exactly once (dup-op regression check)
    assert int(dut.flash.op_count.value) == 6, \
        f"flashtest: op_count={int(dut.flash.op_count.value)}, expected 6"


@cocotb.test(skip=GATES or "flashtimeout" not in HEX)
async def test_flashtimeout(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "flashtimeout", expect_uart=b"flashtimeout done\n")
    # 1 WEN=1 erase-window store in main.c
    assert int(dut.flash.op_count.value) == 1, \
        f"flashtimeout: op_count={int(dut.flash.op_count.value)}, expected 1"


@cocotb.test(skip=GATES or "rv32ui" not in HEX)
async def test_riscv(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, HEX.split("/")[-1], timeout_ns=400_000_000)
