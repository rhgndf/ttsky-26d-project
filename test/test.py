import os
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer, ClockCycles, with_timeout

CLK_NS = 20            # 50 MHz
UART_DIV = 16          # firmware sets DIV=16
GATES = os.getenv("GATES") == "yes"

# which firmware image this sim run loaded (via +HEX=... plusarg)
HEX = cocotb.plusargs.get("HEX", "")


async def uart_rx(dut, chars, timeout_clks=5_000_000):
    """Decode UART bytes on uo_out[0] (DIV=16 clks/bit) until timeout."""
    tx = dut.uo_out
    bit = UART_DIV * CLK_NS
    got = bytearray()
    nclks = 0
    while True:
        while tx.value[0] == 1:
            await RisingEdge(dut.clk)
            nclks += 1
            if nclks > timeout_clks:
                return got
        await Timer(bit // 2 + 2, unit="ns")   # mid start bit, skewed off clk edges
        byte = 0
        for i in range(8):
            await Timer(bit, unit="ns")
            byte |= (1 if tx.value[0] == 1 else 0) << i
        got.append(byte)
        chars.append(byte)
        await Timer(bit, unit="ns")


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0xFF   # UART RX idle high
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
    chars = []
    rx = cocotb.start_soon(uart_rx(dut, chars))
    await reset(dut)
    val = await wait_tohost(dut, timeout_ns)
    rx.kill()
    assert val is not None, f"{name}: no tohost write (uart={bytes(chars)!r})"
    assert int(dut.psram_error.value) == 0, f"{name}: PSRAM protocol error"
    assert val == 1, f"{name}: tohost={val:#x} (uart={bytes(chars)!r})"
    if expect_uart:
        assert expect_uart in bytes(chars), \
            f"{name}: expected {expect_uart!r} in uart output {bytes(chars)!r}"


@cocotb.test(skip=GATES or "hello" not in HEX)
async def test_hello(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "hello", expect_uart=b"Hello RV32I\n")


@cocotb.test(skip=GATES or "memtest" not in HEX)
async def test_memtest(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "memtest", expect_uart=b"memtest done\n")


@cocotb.test(skip=GATES or "traptest" not in HEX)
async def test_traptest(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, "traptest", expect_uart=b"traptest done\n")


@cocotb.test(skip=GATES or "rv32ui" not in HEX)
async def test_riscv(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_NS, unit="ns").start())
    await run_program(dut, HEX.split("/")[-1], timeout_ns=400_000_000)
