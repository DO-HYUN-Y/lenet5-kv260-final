"""Low-level Linux control of the KV260 AlexNet accelerator."""

from __future__ import annotations

import fcntl
import hashlib
import json
import mmap
import os
from pathlib import Path
import struct
import time


DMA_USED_BYTES = 61_766_656
DMA_BUFFER_BYTES = (
    (DMA_USED_BYTES + mmap.PAGESIZE - 1) // mmap.PAGESIZE * mmap.PAGESIZE
)
INPUT_OFFSET = 0
INPUT_BYTES = 401_408
ACTIVATION_A_OFFSET = 401_408
ACTIVATION_A_BYTES = 64_896
ACTIVATION_B_OFFSET = 466_304
ACTIVATION_B_BYTES = 43_264
WEIGHTS_OFFSET = 509_568
WEIGHTS_BYTES = 61_090_496
PARAMETERS_OFFSET = 61_600_128
PARAMETERS_BYTES = 165_504
OUTPUT_OFFSET = 61_765_632
OUTPUT_VALID_BYTES = 1_000
OUTPUT_ALLOC_BYTES = 1_024
BASE_ALIGNMENT = 128

REG_ID = 0x00
REG_CONTROL = 0x04
REG_STATUS = 0x08
REG_JOB_TAG = 0x0C
REG_INPUT_LO = 0x10
REG_ACT_A_LO = 0x18
REG_ACT_B_LO = 0x20
REG_WEIGHTS_LO = 0x28
REG_PARAMETERS_LO = 0x30
REG_OUTPUT_LO = 0x38
REG_DMA_TIMEOUT = 0x40
REG_PROGRESS = 0x44
REG_ERROR = 0x48
REG_CONV_TILES = 0x5C
REG_IRQ_ENABLE = 0x60
REG_IRQ_STATUS = 0x64
REG_CONFIG_STATUS = 0x78
REG_BUILD_CONFIG = 0x7C

CONTROL_SUBMIT = 1 << 0
CONTROL_CLEAR_STATUS = 1 << 1
STATUS_BUSY = 1 << 0
STATUS_DONE = 1 << 3
STATUS_FAILED = 1 << 4
STATUS_FAULT = 1 << 5
STATUS_DMA_ERROR = 1 << 8
EXPECTED_ID = 0x414C0100
EXPECTED_BUILD_CONFIG = 0x080800C8
EXPECTED_CHECKPOINT_SHA256 = (
    "7be5be791159472b1fbf3c69796f7cb30dca7ad8466c2df70058c37116cdee02"
)
EXPECTED_WEIGHT_SHA256 = (
    "07e8583d9c18563672ffeb211746dfc432ba5b96d27039d01563d3fb8679ec3d"
)
EXPECTED_PARAMETER_SHA256 = (
    "0038da71fe9e4fc4454930b8a7f02e36d822e3cd6736388092c1429635c5a2ad"
)
EXPECTED_INPUT_SCALE = 0.020787402400820273

FAULT_DETAIL_NAMES = (
    "compute",
    "data_service",
    "descriptor_bridge",
    "read_router",
    "conv_storage",
    "dma",
    "graph",
    "physical_backend",
)

AXIDMA_MM2S_DMACR = 0x00
AXIDMA_MM2S_DMASR = 0x04
AXIDMA_MM2S_SA = 0x18
AXIDMA_MM2S_SA_MSB = 0x1C
AXIDMA_MM2S_LENGTH = 0x28
AXIDMA_DMACR_RUNSTOP = 1 << 0
AXIDMA_DMACR_RESET = 1 << 2
AXIDMA_DMACR_IOC_IRQEN = 1 << 12
AXIDMA_DMACR_ERR_IRQEN = 1 << 14
AXIDMA_DMASR_ERROR_MASK = 0x00000770
AXIDMA_DMASR_IOC_IRQ = 1 << 12
AXIDMA_DMASR_ERR_IRQ = 1 << 14

REG_SPACE_ACCELERATOR = 0
REG_SPACE_MAIN_DMA = 1
REG_SPACE_CAMERA_DMA = 2
DRIVER_ABI_VERSION = 2

_IOC_NRBITS = 8
_IOC_TYPEBITS = 8
_IOC_SIZEBITS = 14
_IOC_NRSHIFT = 0
_IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS
_IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS
_IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS
_IOC_WRITE = 1
_IOC_READ = 2
_IOC_MAGIC = 0x41
_INFO_FORMAT = "<QQIIIIIIII"
_ACCESS_FORMAT = "<IIII"


def _ioc(direction: int, number: int, size: int) -> int:
    return (
        direction << _IOC_DIRSHIFT
        | _IOC_MAGIC << _IOC_TYPESHIFT
        | number << _IOC_NRSHIFT
        | size << _IOC_SIZESHIFT
    )


IOC_GET_INFO = _ioc(_IOC_READ, 0x00, struct.calcsize(_INFO_FORMAT))
IOC_READ_REG = _ioc(
    _IOC_READ | _IOC_WRITE, 0x01, struct.calcsize(_ACCESS_FORMAT)
)
IOC_WRITE_REG = _ioc(_IOC_WRITE, 0x02, struct.calcsize(_ACCESS_FORMAT))


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


class BoardError(RuntimeError):
    """Hardware or board-runtime contract failure."""


class AlexNetBoard:
    def __init__(self, device: str = "/dev/alexnet_board") -> None:
        self.fd = os.open(device, os.O_RDWR | os.O_CLOEXEC)
        try:
            payload = bytearray(struct.calcsize(_INFO_FORMAT))
            fcntl.ioctl(self.fd, IOC_GET_INFO, payload, True)
            fields = struct.unpack(_INFO_FORMAT, payload)
            self.dma_addr = fields[0]
            self.dma_size = fields[1]
            self.accelerator_reg_size = fields[2]
            self.main_dma_reg_size = fields[3]
            self.camera_dma_reg_size = fields[4]
            self.pl_clock_hz = fields[5]
            self.pl_input_clock_hz = fields[6]
            self.driver_abi_version = fields[7]
            if self.driver_abi_version != DRIVER_ABI_VERSION:
                raise BoardError(
                    f"driver ABI {self.driver_abi_version} != {DRIVER_ABI_VERSION}"
                )
            if self.dma_size < DMA_BUFFER_BYTES:
                raise BoardError(
                    f"DMA buffer {self.dma_size} is smaller than {DMA_BUFFER_BYTES}"
                )
            if self.dma_addr % BASE_ALIGNMENT:
                raise BoardError("DMA physical base is not 128-byte aligned")
            if self.dma_addr + self.dma_size > 1 << 32:
                raise BoardError("DMA allocation is outside the 32-bit address window")
            self.memory = mmap.mmap(
                self.fd,
                self.dma_size,
                flags=mmap.MAP_SHARED,
                prot=mmap.PROT_READ | mmap.PROT_WRITE,
            )
        except Exception:
            os.close(self.fd)
            raise
        self.job_tag = 0

    def close(self) -> None:
        if getattr(self, "memory", None) is not None:
            self.memory.close()
            self.memory = None
        if getattr(self, "fd", None) is not None:
            os.close(self.fd)
            self.fd = None

    def __enter__(self) -> "AlexNetBoard":
        return self

    def __exit__(self, _type, _value, _traceback) -> None:
        self.close()

    def _reg_ioctl(self, command: int, space: int, offset: int, value: int = 0) -> int:
        payload = bytearray(struct.pack(_ACCESS_FORMAT, space, offset, value, 0))
        fcntl.ioctl(self.fd, command, payload, True)
        return struct.unpack(_ACCESS_FORMAT, payload)[2]

    def read_reg(self, space: int, offset: int) -> int:
        return self._reg_ioctl(IOC_READ_REG, space, offset)

    def write_reg(self, space: int, offset: int, value: int) -> None:
        self._reg_ioctl(IOC_WRITE_REG, space, offset, value & 0xFFFFFFFF)

    def _write_accelerator_address(self, low_offset: int, address: int) -> None:
        self.write_reg(REG_SPACE_ACCELERATOR, low_offset, address)
        self.write_reg(REG_SPACE_ACCELERATOR, low_offset + 4, address >> 32)

    def inspect(self) -> dict[str, int]:
        return {
            "id": self.read_reg(REG_SPACE_ACCELERATOR, REG_ID),
            "status": self.read_reg(REG_SPACE_ACCELERATOR, REG_STATUS),
            "progress": self.read_reg(REG_SPACE_ACCELERATOR, REG_PROGRESS),
            "error": self.read_reg(REG_SPACE_ACCELERATOR, REG_ERROR),
            "config_status": self.read_reg(
                REG_SPACE_ACCELERATOR, REG_CONFIG_STATUS
            ),
            "build_config": self.read_reg(REG_SPACE_ACCELERATOR, REG_BUILD_CONFIG),
            "pl_clock_hz": self.pl_clock_hz,
            "pl_input_clock_hz": self.pl_input_clock_hz,
        }

    def require_identity(self) -> None:
        identity = self.read_reg(REG_SPACE_ACCELERATOR, REG_ID)
        if identity != EXPECTED_ID:
            raise BoardError(f"accelerator ID 0x{identity:08x} != 0x{EXPECTED_ID:08x}")
        build_config = self.read_reg(REG_SPACE_ACCELERATOR, REG_BUILD_CONFIG)
        if build_config != EXPECTED_BUILD_CONFIG:
            raise BoardError(
                f"build config 0x{build_config:08x} != 0x{EXPECTED_BUILD_CONFIG:08x}"
            )

    def _copy_file(self, path: Path, offset: int, size: int, expected_hash: str) -> None:
        if path.stat().st_size != size:
            raise BoardError(f"{path} has {path.stat().st_size} bytes, expected {size}")
        if _sha256(path) != expected_hash:
            raise BoardError(f"{path} SHA-256 does not match board manifest")
        cursor = 0
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                self.memory[offset + cursor : offset + cursor + len(chunk)] = chunk
                cursor += len(chunk)

    def load_model(self, board_dir: Path) -> dict:
        manifest = json.loads(
            (board_dir / "board_manifest.json").read_text(encoding="utf-8")
        )
        if manifest.get("format_version") != 1:
            raise BoardError("unsupported board manifest version")
        if manifest.get("checkpoint_sha256") != EXPECTED_CHECKPOINT_SHA256:
            raise BoardError("board manifest checkpoint does not match the frozen model")
        if manifest["weights"].get("sha256") != EXPECTED_WEIGHT_SHA256:
            raise BoardError("board manifest weight hash does not match the frozen model")
        if manifest["parameters"].get("sha256") != EXPECTED_PARAMETER_SHA256:
            raise BoardError("board manifest parameter hash does not match the frozen model")
        if manifest.get("input_scale") != EXPECTED_INPUT_SCALE:
            raise BoardError("board manifest input scale does not match the frozen model")
        self._copy_file(
            board_dir / manifest["weights"]["file"],
            WEIGHTS_OFFSET,
            WEIGHTS_BYTES,
            EXPECTED_WEIGHT_SHA256,
        )
        self._copy_file(
            board_dir / manifest["parameters"]["file"],
            PARAMETERS_OFFSET,
            PARAMETERS_BYTES,
            EXPECTED_PARAMETER_SHA256,
        )
        if len(manifest.get("categories", [])) != OUTPUT_VALID_BYTES:
            raise BoardError("board manifest does not contain 1,000 ImageNet categories")
        return manifest

    def configure(self, dma_timeout_cycles: int = 100_000_000) -> None:
        self.require_identity()
        addresses = (
            (REG_INPUT_LO, INPUT_OFFSET),
            (REG_ACT_A_LO, ACTIVATION_A_OFFSET),
            (REG_ACT_B_LO, ACTIVATION_B_OFFSET),
            (REG_WEIGHTS_LO, WEIGHTS_OFFSET),
            (REG_PARAMETERS_LO, PARAMETERS_OFFSET),
            (REG_OUTPUT_LO, OUTPUT_OFFSET),
        )
        for register, offset in addresses:
            self._write_accelerator_address(register, self.dma_addr + offset)
        self.write_reg(REG_SPACE_ACCELERATOR, REG_DMA_TIMEOUT, dma_timeout_cycles)
        config_status = self.read_reg(REG_SPACE_ACCELERATOR, REG_CONFIG_STATUS)
        if config_status & 0x7 != 0x7:
            raise BoardError(f"accelerator rejected buffer configuration: 0x{config_status:08x}")

    def write_input(self, packed_frame: bytes) -> None:
        if len(packed_frame) != INPUT_BYTES:
            raise BoardError(f"camera frame has {len(packed_frame)} bytes, expected {INPUT_BYTES}")
        self.memory[INPUT_OFFSET : INPUT_OFFSET + INPUT_BYTES] = packed_frame

    def _reset_camera_dma(self, timeout_s: float = 0.1) -> None:
        self.write_reg(
            REG_SPACE_CAMERA_DMA, AXIDMA_MM2S_DMACR, AXIDMA_DMACR_RESET
        )
        deadline = time.monotonic() + timeout_s
        while self.read_reg(REG_SPACE_CAMERA_DMA, AXIDMA_MM2S_DMACR) & AXIDMA_DMACR_RESET:
            if time.monotonic() >= deadline:
                raise BoardError("camera DMA reset timed out")

    def _start_camera_dma(self) -> None:
        self._reset_camera_dma()
        self.write_reg(
            REG_SPACE_CAMERA_DMA,
            AXIDMA_MM2S_DMASR,
            AXIDMA_DMASR_IOC_IRQ | AXIDMA_DMASR_ERR_IRQ,
        )
        self.write_reg(
            REG_SPACE_CAMERA_DMA,
            AXIDMA_MM2S_DMACR,
            AXIDMA_DMACR_RUNSTOP
            | AXIDMA_DMACR_IOC_IRQEN
            | AXIDMA_DMACR_ERR_IRQEN,
        )
        input_address = self.dma_addr + INPUT_OFFSET
        self.write_reg(REG_SPACE_CAMERA_DMA, AXIDMA_MM2S_SA, input_address)
        self.write_reg(REG_SPACE_CAMERA_DMA, AXIDMA_MM2S_SA_MSB, input_address >> 32)
        self.write_reg(
            REG_SPACE_CAMERA_DMA, AXIDMA_MM2S_LENGTH, INPUT_BYTES
        )

    def infer(self, packed_frame: bytes, timeout_s: float = 10.0) -> bytes:
        status = self.read_reg(REG_SPACE_ACCELERATOR, REG_STATUS)
        if status & STATUS_BUSY:
            raise BoardError("accelerator is already busy")
        self.write_input(packed_frame)
        self.memory[OUTPUT_OFFSET : OUTPUT_OFFSET + OUTPUT_ALLOC_BYTES] = bytes(
            OUTPUT_ALLOC_BYTES
        )
        self.write_reg(REG_SPACE_ACCELERATOR, REG_IRQ_STATUS, 0xF)
        self.write_reg(
            REG_SPACE_ACCELERATOR, REG_CONTROL, CONTROL_CLEAR_STATUS
        )
        self.job_tag = (self.job_tag + 1) & 0xFFFF
        self.write_reg(REG_SPACE_ACCELERATOR, REG_JOB_TAG, self.job_tag)

        # One camera-DMA launch fills the PL UltraRAM frame cache. The cache
        # replays the retained 224x224 RGB tensor for all eight Conv1 N8 output
        # tiles, eliminating seven DDR reads and seven PS-side DMA restarts.
        # Starting MM2S first is safe: AXI-Stream backpressure holds its first
        # pixel until the submitted graph arms the cache.
        self._start_camera_dma()
        self.write_reg(REG_SPACE_ACCELERATOR, REG_CONTROL, CONTROL_SUBMIT)

        deadline = time.monotonic() + timeout_s
        camera_done = False
        while True:
            camera_status = self.read_reg(
                REG_SPACE_CAMERA_DMA, AXIDMA_MM2S_DMASR
            )
            if camera_status & (AXIDMA_DMASR_ERROR_MASK | AXIDMA_DMASR_ERR_IRQ):
                raise BoardError(f"camera DMA failed: 0x{camera_status:08x}")
            camera_done = camera_done or bool(
                camera_status & AXIDMA_DMASR_IOC_IRQ
            )
            status = self.read_reg(REG_SPACE_ACCELERATOR, REG_STATUS)
            if status & (STATUS_FAILED | STATUS_FAULT | STATUS_DMA_ERROR):
                progress = self.read_reg(REG_SPACE_ACCELERATOR, REG_PROGRESS)
                error = self.read_reg(REG_SPACE_ACCELERATOR, REG_ERROR)
                detail = (error >> 24) & 0xFF
                sources = ",".join(
                    name
                    for bit, name in enumerate(FAULT_DETAIL_NAMES)
                    if detail & (1 << bit)
                ) or "none"
                raise BoardError(
                    f"accelerator failed: status=0x{status:08x} "
                    f"progress=0x{progress:08x} error=0x{error:08x} "
                    f"fault_sources={sources}"
                )
            if status & STATUS_DONE and camera_done:
                break
            if time.monotonic() >= deadline:
                progress = self.read_reg(REG_SPACE_ACCELERATOR, REG_PROGRESS)
                raise BoardError(
                    f"inference timed out: status=0x{status:08x} "
                    f"camera=0x{camera_status:08x} progress=0x{progress:08x}"
                )
            time.sleep(0.001)
        return bytes(self.memory[OUTPUT_OFFSET : OUTPUT_OFFSET + OUTPUT_VALID_BYTES])
