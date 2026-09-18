"""PS control contract checks with an in-memory CSR/device double."""
import unittest
from alexnet.software.runtime import alexnet_board as abi
from .alexnet_row_stationary_board import RowStationaryBoard, EXPECTED_ID, EXPECTED_BUILD


class Memory:
    def __init__(self):
        self.values = {}
    def __setitem__(self,key,value):
        self.values[(key.start,key.stop)] = bytes(value)
    def __getitem__(self,key):
        return self.values.get((key.start,key.stop),bytes(key.stop-key.start))


class FakeBoard(RowStationaryBoard):
    def __init__(self):
        self.memory=Memory(); self.job_tag=0; self.writes=[]; self.submitted=False
        self.status=0
        self.registers={abi.REG_ID:EXPECTED_ID,abi.REG_BUILD_CONFIG:EXPECTED_BUILD,
                        0xD4:56104,0xE8:1305,0xD0:9733}
        for offset,value in [(0xB0,3707168),(0xB8,582504),(0xC0,156334784),
                             (0xC8,2084512),(0xE0,160624456),(0x94,714188480)]:
            self.registers[offset]=value&0xFFFFFFFF
            self.registers[offset+4]=value>>32
    def read_reg(self,space,offset):
        assert space==abi.REG_SPACE_ACCELERATOR
        if offset==abi.REG_STATUS:
            return self.status or (abi.STATUS_DONE if self.submitted else 0)
        return self.registers.get(offset,0)
    def write_reg(self,space,offset,value):
        self.writes.append((space,offset,value))
        if offset==abi.REG_CONTROL and value==abi.CONTROL_SUBMIT:
            self.submitted=True
    def inspect(self):
        return {'status':self.status}


class BoardTests(unittest.TestCase):
    def test_raw_ddr_input_submit_without_camera_dma(self):
        board=FakeBoard(); result=board.infer(bytes(abi.INPUT_BYTES))
        self.assertEqual(len(result),1000)
        self.assertTrue(board.submitted)
        self.assertTrue(all(space==abi.REG_SPACE_ACCELERATOR for space,_,_ in board.writes))
        self.assertIn((0,abi.REG_JOB_TAG,1),board.writes)
        self.assertEqual(board.telemetry()['weight_axis_bytes'],156334784)

    def test_wrong_identity_stops_before_submit(self):
        board=FakeBoard();board.registers[abi.REG_ID]=abi.EXPECTED_ID
        with self.assertRaises(abi.BoardError):board.infer(bytes(abi.INPUT_BYTES))
        self.assertFalse(board.submitted)

    def test_pending_and_latched_fault_stop_before_submit(self):
        for status in [1,2,abi.STATUS_FAULT,abi.STATUS_DMA_ERROR]:
            with self.subTest(status=status):
                board=FakeBoard();board.status=status
                with self.assertRaises(abi.BoardError):board.infer(bytes(abi.INPUT_BYTES))
                self.assertFalse(board.submitted)

    def test_done_requires_full_graph_counters(self):
        board=FakeBoard();board.registers[0xD4]=1
        with self.assertRaisesRegex(abi.BoardError,'incomplete RS graph'):
            board.infer(bytes(abi.INPUT_BYTES))

    def test_short_input_is_rejected(self):
        board=FakeBoard()
        with self.assertRaises(abi.BoardError):board.infer(bytes(16))
        self.assertFalse(board.submitted)

    def test_read_counter_retries_rollover(self):
        board=FakeBoard();original=board.read_reg;high_reads=iter([0,1,1,1])
        board.read_reg=lambda space,offset:next(high_reads) if offset==0xB4 else 7 if offset==0xB0 else original(space,offset)
        self.assertEqual(board._read_counter(0xB0),(1<<32)|7)


if __name__=='__main__':unittest.main()
