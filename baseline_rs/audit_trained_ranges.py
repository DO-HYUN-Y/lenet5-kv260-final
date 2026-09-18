"""Bound every frozen neuron's accumulator for all legal INT8 input values.

Conv1 accepts signed INT8; every later layer consumes ReLU/pool outputs in
0..127. Summing positive/negative weight magnitudes bounds all K prefixes too.
No single inference vector is used to establish these overflow bounds.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import struct

GEOMETRY = [("conv1",64,363),("conv2",192,1600),("conv3",384,1728),
            ("conv4",256,3456),("conv5",256,2304),("fc6",4096,9216),
            ("fc7",4096,4096),("fc8",1000,4096)]


def audit(model_root: Path) -> dict:
    root = Path(__file__).resolve().parent
    frozen = json.loads((root/'config/frozen_model_identity.json').read_text())
    manifest = json.loads((model_root/'rs_manifest.json').read_text())
    for key in ('layout', 'checkpoint_sha256', 'quantization_contract_sha256'):
        if manifest.get(key) != frozen[key]:raise ValueError('Model identity differs: '+key)
    blobs = {}
    for key in ('weights', 'parameters'):
        record = manifest[key];data = (model_root/record['file']).read_bytes()
        if len(data) != frozen[key]['bytes'] or hashlib.sha256(data).hexdigest() != frozen[key]['sha256']:
            raise ValueError('Frozen model bytes differ: '+key)
        blobs[key] = data
    weights = memoryview(blobs['weights']).cast('b')
    offset = param_offset = 0
    layers = []
    for name, channels, k in GEOMETRY:
        record = manifest['layers'][name]
        if (record['n'], record['k'], record['offset'], record['parameter_offset']) != (channels,k,offset,param_offset):
            raise ValueError('Model geometry differs: '+name)
        input_min, input_max = (-128,127) if name=='conv1' else (0,127)
        lower, upper, bias_lower, bias_upper = 0,0,0,0
        for n in range(channels):
            row = weights[offset+n*k:offset+(n+1)*k]
            positive = sum(w for w in row if w>0)
            negative = -sum(w for w in row if w<0)
            lo = input_min*positive-input_max*negative
            hi = input_max*positive-input_min*negative
            bias = struct.unpack_from('<i',blobs['parameters'],param_offset+n*16)[0]
            if not (-(1<<26)<=lo<=hi<(1<<26)):
                raise ValueError(f'27-bit accumulator can overflow: {name}/{n} [{lo},{hi}]')
            if not (-(1<<31)<=lo+bias<=hi+bias<(1<<31)):
                raise ValueError(f'32-bit postbias can overflow: {name}/{n}')
            lower, upper = min(lower,lo), max(upper,hi)
            bias_lower, bias_upper = min(bias_lower,lo+bias), max(bias_upper,hi+bias)
        layers.append(dict(layer=name, output_channels=channels, input_range=[input_min,input_max],
                           accumulator_bounds=[lower,upper], postbias_bounds=[bias_lower,bias_upper]))
        offset += channels*k;param_offset += channels*16
    if offset!=len(weights) or param_offset!=len(blobs['parameters']):
        raise ValueError('Model coverage is incomplete')
    return dict(scope='Conservative trained-weight worst-case accumulator bounds for every legal input, including all K continuation subsets',
                weights_sha256=frozen['weights']['sha256'], parameters_sha256=frozen['parameters']['sha256'],
                accumulator_bits=27, postbias_bits=32, layers=layers,
                all_neurons_and_k_continuations_overflow_safe=True, physical_board_inference_verified=False)


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model-root',type=Path,required=True)
    p.add_argument('--output',type=Path,default=Path(__file__).resolve().parent/'reports/trained_accumulator_bounds.json')
    args=p.parse_args();result=audit(args.model_root)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(result,indent=2)+'\n')
    print('RS_TRAINED_ACCUMULATOR_BOUNDS_PASS neurons=10344 accumulator=27 postbias=32')
if __name__=='__main__':main()
