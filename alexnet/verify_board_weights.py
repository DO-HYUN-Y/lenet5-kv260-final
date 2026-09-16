"""Verify hashes, offsets, and byte order of exported KV260 weight images."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


DEFAULT_BOARD_DIR = Path("alexnet_output/int8_mlcommons500_board")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_conv_chunks(logical: bytes, shape: list[int], output_tile: int):
    """Repack OIHW independently as scheduler-N-tile/K/N16 chunks."""

    outputs, inputs, kernel_h, kernel_w = shape
    for output_base in range(0, outputs, output_tile):
        output_limit = min(output_base + output_tile, outputs)
        chunk = bytearray()
        for kernel_y in range(kernel_h):
            for kernel_x in range(kernel_w):
                for input_channel in range(inputs):
                    for output_channel in range(output_base, output_limit):
                        logical_index = (
                            (output_channel * inputs + input_channel) * kernel_h
                            + kernel_y
                        ) * kernel_w + kernel_x
                        chunk.append(logical[logical_index])
        yield bytes(chunk)


def expected_fc_chunks(logical: bytes, shape: list[int], output_tile: int):
    """Repack NK independently as padded N16/K/N-lane chunks."""

    outputs, inputs = shape
    for output_base in range(0, outputs, output_tile):
        output_limit = min(output_base + output_tile, outputs)
        chunk = bytearray(inputs * output_tile)
        write_index = 0
        for input_index in range(inputs):
            for output_channel in range(output_base, output_base + output_tile):
                if output_channel < output_limit:
                    chunk[write_index] = logical[
                        output_channel * inputs + input_index
                    ]
                write_index += 1
        yield bytes(chunk)


def verify(args: argparse.Namespace) -> None:
    board_dir = args.board_dir
    manifest_path = board_dir / "board_manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    board_weight_path = board_dir / manifest["weights"]["file"]
    board_parameter_path = board_dir / manifest["parameters"]["file"]
    board_weights = board_weight_path.read_bytes()
    board_parameters = board_parameter_path.read_bytes()

    for description, path, payload, record in (
        ("weight", board_weight_path, board_weights, manifest["weights"]),
        ("parameter", board_parameter_path, board_parameters, manifest["parameters"]),
    ):
        if len(payload) != record["bytes"]:
            raise RuntimeError(f"{description} image byte count mismatch")
        if sha256_file(path) != record["sha256"]:
            raise RuntimeError(f"{description} image SHA-256 mismatch")

    weight_cursor = 0
    parameter_cursor = 0
    for name, record in manifest["layers"].items():
        logical_path = board_dir / record["logical_file"]
        parameter_path = board_dir / record["parameter_file"]
        logical = logical_path.read_bytes()
        parameters = parameter_path.read_bytes()
        if hashlib.sha256(logical).hexdigest() != record["logical_sha256"]:
            raise RuntimeError(f"{name} logical weight SHA-256 mismatch")
        if hashlib.sha256(parameters).hexdigest() != record["parameter_sha256"]:
            raise RuntimeError(f"{name} parameter SHA-256 mismatch")
        if weight_cursor != record["weight_offset"]:
            raise RuntimeError(f"{name} weight offset is not contiguous")
        if parameter_cursor != record["parameter_offset"]:
            raise RuntimeError(f"{name} parameter offset is not contiguous")

        packed_digest = hashlib.sha256()
        chunks = (
            expected_conv_chunks(
                logical, record["shape"], record["output_tile_channels"]
            )
            if record["logical_layout"] == "OIHW"
            else expected_fc_chunks(
                logical, record["shape"], record["output_tile_channels"]
            )
        )
        layer_start = weight_cursor
        for chunk in chunks:
            board_chunk = board_weights[weight_cursor : weight_cursor + len(chunk)]
            if board_chunk != chunk:
                raise RuntimeError(f"{name} board weight byte order mismatch")
            packed_digest.update(chunk)
            weight_cursor += len(chunk)
        if weight_cursor - layer_start != record["weight_bytes"]:
            raise RuntimeError(f"{name} packed weight byte count mismatch")
        if packed_digest.hexdigest() != record["packed_sha256"]:
            raise RuntimeError(f"{name} packed weight SHA-256 mismatch")

        board_parameter_slice = board_parameters[
            parameter_cursor : parameter_cursor + len(parameters)
        ]
        if board_parameter_slice != parameters:
            raise RuntimeError(f"{name} board parameter order mismatch")
        if len(parameters) != record["parameter_bytes"]:
            raise RuntimeError(f"{name} parameter byte count mismatch")
        parameter_cursor += len(parameters)

    if weight_cursor != len(board_weights):
        raise RuntimeError("unverified bytes remain in the board weight image")
    if parameter_cursor != len(board_parameters):
        raise RuntimeError("unverified bytes remain in the board parameter image")

    print(
        "ALEXNET_BOARD_WEIGHT_VERIFY_PASS "
        f"layers={len(manifest['layers'])} weight_bytes={weight_cursor} "
        f"parameter_bytes={parameter_cursor}"
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--board-dir", type=Path, default=DEFAULT_BOARD_DIR)
    return parser.parse_args()


if __name__ == "__main__":
    verify(parse_args())
