"""Linux PS runner for the pure RS bitstream and the existing coherent allocator.

No camera DMA launch: raw quantized N8 input is gathered directly from DDR.
Telemetry counts accepted AXI-Stream valid bytes, not physical DDR bus traffic.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import time

from alexnet.software.runtime import alexnet_board as abi

EXPECTED_ID = 0x52530100
EXPECTED_BUILD = 0x088000C8
WEIGHT_BYTES = 61_090_496
WEIGHT_SHA256 = 'd0cb5a3472ad4d4ded09807c8fbe4682e39eb10c29930593cb8e6ee40ea334d8'
CONTRACT_SHA256 = '1a85423e46a77b088703428b00292b14b6d86c1f835c697537305f04641207d0'


class RowStationaryBoard(abi.AlexNetBoard):
    def require_identity(self) -> None:
        identity = self.read_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_ID)
        build = self.read_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_BUILD_CONFIG)
        if (identity, build) != (EXPECTED_ID, EXPECTED_BUILD):
            raise abi.BoardError(f'pure RS identity/build mismatch: 0x{identity:08x}/0x{build:08x}')

    def load_model(self, model_dir: Path) -> dict:
        manifest = json.loads((model_dir/'rs_manifest.json').read_text())
        if (manifest.get('layout') != 'N_HCW_for_conv_NK_for_FC' or
                manifest.get('checkpoint_sha256') != abi.EXPECTED_CHECKPOINT_SHA256 or
                manifest.get('quantization_contract_sha256') != CONTRACT_SHA256 or
                manifest.get('input_scale') != abi.EXPECTED_INPUT_SCALE or
                manifest['weights'].get('sha256') != WEIGHT_SHA256 or
                manifest['weights'].get('bytes') != WEIGHT_BYTES or
                manifest['parameters'].get('sha256') != abi.EXPECTED_PARAMETER_SHA256 or
                manifest['parameters'].get('bytes') != abi.PARAMETERS_BYTES or
                len(manifest.get('categories', [])) != 1000):
            raise abi.BoardError('RS manifest does not match the frozen trained model')
        self._copy_file(model_dir/manifest['weights']['file'], abi.WEIGHTS_OFFSET, WEIGHT_BYTES, WEIGHT_SHA256)
        self._copy_file(model_dir/manifest['parameters']['file'], abi.PARAMETERS_OFFSET,
                        abi.PARAMETERS_BYTES, abi.EXPECTED_PARAMETER_SHA256)
        return manifest

    def _read_counter(self, offset: int) -> int:
        # Stable after DONE; also tolerate a running counter crossing 2^32.
        for _ in range(8):
            high = self.read_reg(abi.REG_SPACE_ACCELERATOR, offset+4)
            low = self.read_reg(abi.REG_SPACE_ACCELERATOR, offset)
            if high == self.read_reg(abi.REG_SPACE_ACCELERATOR, offset+4):
                return (high<<32)|low
        raise abi.BoardError('telemetry counter did not stabilize')

    def telemetry(self) -> dict:
        read = lambda offset: self.read_reg(abi.REG_SPACE_ACCELERATOR, offset)
        return {'scope':'per-job accepted AXI-Stream valid bytes; physical DDR bursts not measured',
                'main_read_axis_bytes':self._read_counter(0xB0),
                'main_write_axis_bytes':self._read_counter(0xB8),
                'weight_axis_bytes':self._read_counter(0xC0),
                'gather_requested_bytes':self._read_counter(0xC8),
                'total_axis_bytes':self._read_counter(0xE0),
                'stored_packets':read(0xD0),'completed_graph_commands':read(0xD4),
                'main_completed_transfers':read(0xD8),'issued_dma_commands':read(0xDC),
                'completed_input_tiles':read(0xE8),
                'useful_macs':self._read_counter(0x94)}

    def infer(self, packed_frame: bytes, timeout_s: float = 120.0) -> bytes:
        self.require_identity()
        status = self.read_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_STATUS)
        if status & 3:
            raise abi.BoardError('accelerator is busy or has a pending job')
        if status & (abi.STATUS_FAULT|abi.STATUS_DMA_ERROR):
            raise abi.BoardError('hardware fault is latched; reset the PL before another inference')
        self.write_input(packed_frame)
        self.memory[abi.OUTPUT_OFFSET:abi.OUTPUT_OFFSET+abi.OUTPUT_ALLOC_BYTES] = bytes(abi.OUTPUT_ALLOC_BYTES)
        self.write_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_IRQ_STATUS, 0xF)
        self.write_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_CONTROL, abi.CONTROL_CLEAR_STATUS)
        self.job_tag = (self.job_tag+1)&0xFFFF
        self.write_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_JOB_TAG, self.job_tag)
        self.write_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_CONTROL, abi.CONTROL_SUBMIT)
        deadline = time.monotonic()+timeout_s
        while True:
            status = self.read_reg(abi.REG_SPACE_ACCELERATOR, abi.REG_STATUS)
            if status & (abi.STATUS_FAILED|abi.STATUS_FAULT|abi.STATUS_DMA_ERROR):
                raise abi.BoardError(f'pure RS inference failed: {self.inspect()}')
            if status & abi.STATUS_DONE:
                break
            if time.monotonic() >= deadline:
                raise abi.BoardError(f'pure RS inference timed out: {self.inspect()}')
            time.sleep(0.001)
        counters = self.telemetry()
        if (counters['completed_graph_commands'], counters['completed_input_tiles'],
                counters['useful_macs'], counters['weight_axis_bytes']) != (
                56_104, 1_305, 714_188_480, 156_334_784):
            raise abi.BoardError(f'incomplete RS graph at DONE: {counters}')
        return bytes(self.memory[abi.OUTPUT_OFFSET:abi.OUTPUT_OFFSET+abi.OUTPUT_VALID_BYTES])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device',default='/dev/alexnet_board')
    parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--input',type=Path,required=True,help='401408-byte signed INT8 N8 raster')
    parser.add_argument('--report',type=Path,required=True)
    parser.add_argument('--timeout',type=float,default=120.0)
    args = parser.parse_args()
    with RowStationaryBoard(args.device) as board:
        model = board.load_model(args.model)
        board.configure()
        packed_input = args.input.read_bytes()
        started = time.monotonic()
        logits = board.infer(packed_input,args.timeout)
        scores = [b if b<128 else b-256 for b in logits]
        top = sorted(range(1000),key=lambda n:scores[n],reverse=True)[:5]
        result = {'elapsed_seconds':time.monotonic()-started,'telemetry':board.telemetry(),
                  'accelerator_id':board.read_reg(abi.REG_SPACE_ACCELERATOR,abi.REG_ID),
                  'build_config':board.read_reg(abi.REG_SPACE_ACCELERATOR,abi.REG_BUILD_CONFIG),
                  'input_bytes':len(packed_input),
                  'input_sha256':hashlib.sha256(packed_input).hexdigest(),
                  'checkpoint_sha256':model['checkpoint_sha256'],
                  'quantization_contract_sha256':model['quantization_contract_sha256'],
                  'weights_sha256':model['weights']['sha256'],
                  'parameters_sha256':model['parameters']['sha256'],
                  'top5':[{'index':n,'class':model['categories'][n],'int8_logit':scores[n]} for n in top]}
        args.report.parent.mkdir(parents=True,exist_ok=True)
        args.report.write_text(json.dumps(result,indent=2)+'\n')
        args.report.with_suffix('.logits.bin').write_bytes(logits)


if __name__=='__main__':
    main()
