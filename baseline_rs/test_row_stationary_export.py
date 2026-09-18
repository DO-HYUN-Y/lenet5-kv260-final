import unittest
from .export_row_stationary_weights import pack_layer

class StreamingWeightOrder(unittest.TestCase):
    def test_conv_reduction_matches_filter_row_order(self):
        n,c,h,w=2,3,2,2
        raw=bytes(range(n*c*h*w))
        expected=bytes(raw[((o*c+i)*h+y)*w+x]
                       for o in range(n) for y in range(h) for i in range(c) for x in range(w))
        self.assertEqual(pack_layer(raw,[n,c,h,w]),expected)
        # The entire filter row precedes the next channel row; HWIC
        # interchange would silently permute the reduction inputs.
        self.assertEqual(expected[:6],bytes([0,1,4,5,8,9]))

    def test_fc_nk_is_preserved_including_signed_bytes(self):
        raw=bytes([128,255,0,1,127,128,3,4,5,6])
        self.assertEqual(pack_layer(raw,[2,5]),raw)

    def test_truncated_blob_is_rejected(self):
        with self.assertRaises(ValueError): pack_layer(b'\x00',[2,3,2,2])

if __name__=='__main__': unittest.main()
