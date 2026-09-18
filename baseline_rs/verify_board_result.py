"""Compare a real RS PS-runner result with the frozen C++ golden tensor."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
from .audit_row_stationary_traffic import predict_rs
from .software.runtime.alexnet_row_stationary_board import (
    EXPECTED_ID, EXPECTED_BUILD, WEIGHT_SHA256, CONTRACT_SHA256)
from alexnet.software.runtime import alexnet_board as abi


def verify(result: dict, actual: bytes, vectors: dict, golden: bytes, packed_input: bytes) -> dict:
    identities = {
        'accelerator_id': EXPECTED_ID, 'build_config': EXPECTED_BUILD,
        'checkpoint_sha256': abi.EXPECTED_CHECKPOINT_SHA256,
        'quantization_contract_sha256': CONTRACT_SHA256,
        'weights_sha256': WEIGHT_SHA256,
        'parameters_sha256': abi.EXPECTED_PARAMETER_SHA256,
    }
    for key, expected in identities.items():
        if result.get(key) != expected:
            raise ValueError('Board identity/model differs: '+key)
    if (vectors.get('trained_weights_sha256'), vectors.get('parameters_sha256')) != (
            WEIGHT_SHA256, abi.EXPECTED_PARAMETER_SHA256):
        raise ValueError('Golden vectors use a different model')
    for name, data, size in [('input_n8.bin', packed_input, abi.INPUT_BYTES), ('fc8_n8.bin', golden, 1000)]:
        record = vectors['full_tensors'][name]
        if len(data) != size or len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError('Golden hash/size differs: '+name)
    input_record = vectors['full_tensors']['input_n8.bin']
    if (result.get('input_bytes'), result.get('input_sha256')) != (input_record['bytes'], input_record['sha256']):
        raise ValueError('Board consumed a different input')
    if len(actual) != 1000 or actual != golden:
        raise ValueError('Board FC8 logits differ from frozen golden')
    totals = predict_rs()
    counters = result['telemetry']
    for key in ('main_read_axis_bytes', 'main_write_axis_bytes', 'weight_axis_bytes', 'gather_requested_bytes', 'useful_macs'):
        expected = sum(t.get(key, 0) for t in totals)
        if counters.get(key) != expected:
            raise ValueError('Board traffic differs: '+key)
    if (counters.get('completed_graph_commands'), counters.get('completed_input_tiles')) != (56104, 1305):
        raise ValueError('Board graph is incomplete')
    expected_total = sum(counters[key] for key in ('main_read_axis_bytes', 'main_write_axis_bytes', 'weight_axis_bytes'))
    if counters.get('total_axis_bytes') != expected_total:
        raise ValueError('Board total traffic differs')
    return dict(result, frozen_golden_logits_match=True,
                expected_fc8_sha256=vectors['full_tensors']['fc8_n8.bin']['sha256'],
                verification_scope='Final FC8 logits and per-job AXI-Stream telemetry; physical DDR bursts are not measured')


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--report', type=Path, required=True)
    p.add_argument('--vector-root', type=Path, required=True)
    args = p.parse_args()
    vectors = json.loads((args.vector_root/'manifest.json').read_text())
    result = verify(json.loads(args.report.read_text()), args.report.with_suffix('.logits.bin').read_bytes(), vectors,
                    (args.vector_root/'fc8_n8.bin').read_bytes(), (args.vector_root/'input_n8.bin').read_bytes())
    args.report.write_text(json.dumps(result, indent=2)+'\n')
    print('RS_BOARD_FC8_GOLDEN_MATCH telemetry=PASS')


if __name__ == '__main__':
    main()
