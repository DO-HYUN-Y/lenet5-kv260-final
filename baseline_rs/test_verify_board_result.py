"""Reject board results that belong to another run or hide traffic errors."""
import copy
import hashlib
import unittest
from unittest.mock import patch
from .verify_board_result import verify
from .software.runtime.alexnet_row_stationary_board import EXPECTED_ID, EXPECTED_BUILD, WEIGHT_SHA256, CONTRACT_SHA256
from alexnet.software.runtime import alexnet_board as abi


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.input = bytes(abi.INPUT_BYTES)
        self.golden = bytes(n % 256 for n in range(1000))
        self.vectors = {'trained_weights_sha256':WEIGHT_SHA256, 'parameters_sha256':abi.EXPECTED_PARAMETER_SHA256,
                        'full_tensors':{}}
        for name, data in [('input_n8.bin', self.input), ('fc8_n8.bin', self.golden)]:
            self.vectors['full_tensors'][name] = {'bytes':len(data), 'sha256':hashlib.sha256(data).hexdigest()}
        self.counters = dict(main_read_axis_bytes=3707168, main_write_axis_bytes=582504, weight_axis_bytes=156334784,
                             gather_requested_bytes=2084512, useful_macs=714188480)
        self.result = dict(accelerator_id=EXPECTED_ID, build_config=EXPECTED_BUILD,
                           checkpoint_sha256=abi.EXPECTED_CHECKPOINT_SHA256,
                           quantization_contract_sha256=CONTRACT_SHA256, weights_sha256=WEIGHT_SHA256,
                           parameters_sha256=abi.EXPECTED_PARAMETER_SHA256,
                           input_bytes=len(self.input), input_sha256=hashlib.sha256(self.input).hexdigest(),
                           telemetry=dict(self.counters, completed_graph_commands=56104, completed_input_tiles=1305,
                                          total_axis_bytes=160624456))
        self.policy = patch('baseline_rs.verify_board_result.predict_rs', return_value=[self.counters])
        self.policy.start()
        self.addCleanup(self.policy.stop)

    def check(self, result=None, actual=None):
        return verify(result or self.result, self.golden if actual is None else actual,
                      self.vectors, self.golden, self.input)

    def test_matching_run(self):
        self.assertTrue(self.check()['frozen_golden_logits_match'])

    def test_changed_logit(self):
        changed = bytes([self.golden[0] ^ 1]) + self.golden[1:]
        with self.assertRaisesRegex(ValueError, 'FC8'):self.check(actual=changed)

    def test_wrong_model_identity_input(self):
        for key in ('accelerator_id', 'build_config', 'weights_sha256', 'parameters_sha256', 'input_sha256'):
            with self.subTest(key=key):
                result = copy.deepcopy(self.result); result[key] = 0
                with self.assertRaises(ValueError):self.check(result)

    def test_incomplete_graph_or_wrong_traffic(self):
        for key in ('completed_graph_commands', 'completed_input_tiles', 'total_axis_bytes', *self.counters):
            with self.subTest(key=key):
                result = copy.deepcopy(self.result); result['telemetry'][key] -= 1
                with self.assertRaises(ValueError):self.check(result)

    def test_corrupt_golden_rejected(self):
        self.vectors['full_tensors']['fc8_n8.bin']['sha256'] = 'wrong'
        with self.assertRaisesRegex(ValueError, 'Golden'):self.check()


if __name__ == '__main__':unittest.main()
