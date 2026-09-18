"""Reorder frozen logical weights for the RS row streaming interface, without requantizing.

Every Conv byte is inverse-reordered and compared with frozen OIHW bytes.
Input: board_manifest.json produced by alexnet.export_board_weights.
Output: N-major weights; for Conv, K uses (kernel_y,input_channel,kernel_x) row order.
An N-token DMA descriptor reads layer_offset + N*K_total + k_offset, k_count
bytes. Low-first 128-bit beats use TKEEP on the final K tail. No weight tile
is replayed. Numerical parameters retain their original bytes and offsets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

def pack_layer(raw: bytes, shape: list[int]) -> bytes:
    if len(shape)==2:
        n,k=shape
        if len(raw)!=n*k: raise ValueError('FC weight length does not match NK')
        return raw
    if len(shape)!=4: raise ValueError('expected OIHW or NK weights')
    n,c,h,w=shape
    if min(shape)<1 or len(raw)!=n*c*h*w: raise ValueError('Conv weight length does not match OIHW')
    area=h*w; stride=c*area
    # OIHW -> N,ky,channel,kx. One column scans a contiguous filter row.
    packed=b''.join(raw[(o*c+ch)*area+y*w:(o*c+ch)*area+(y+1)*w]
                    for o in range(n) for y in range(h) for ch in range(c))
    restored=bytearray(len(raw))
    for o in range(n):
        for y in range(h):
            for ch in range(c):
                src=((o*h+y)*c+ch)*w;dst=(o*c+ch)*area+y*w
                restored[dst:dst+w]=packed[src:src+w]
    if restored!=raw: raise ValueError('RS inverse reordering changed logical weights')
    return packed

def checked_bytes(path: Path, expected_sha: str) -> bytes:
    raw=path.read_bytes()
    if hashlib.sha256(raw).hexdigest()!=expected_sha:
        raise ValueError(f'frozen weight/parameter hash mismatch: {path}')
    return raw

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--board-manifest',type=Path,required=True)
    p.add_argument('--output-dir',type=Path,required=True)
    args=p.parse_args(); source=json.loads(args.board_manifest.read_text())
    base=args.board_manifest.parent; result=bytearray(); layers={}
    for name in ['conv1','conv2','conv3','conv4','conv5','fc6','fc7','fc8']:
        layer=source['layers'][name]
        shape=layer['shape']; raw=checked_bytes(base/layer['logical_file'],layer['logical_sha256'])
        packed=pack_layer(raw,shape)
        n=shape[0]; k=len(packed)//n
        layers[name]={'offset':len(result),'bytes':len(packed),'n':n,'k':k,
                      'sha256':hashlib.sha256(packed).hexdigest(),
                      'logical_sha256':layer['logical_sha256'],
                      'parameter_offset':layer['parameter_offset']}
        result.extend(packed)
    if len(result)!=61090496: raise ValueError('unexpected frozen AlexNet logical weight size')
    parameters=checked_bytes(base/source['parameters']['file'],source['parameters']['sha256'])
    if len(parameters)!=165504: raise ValueError('unexpected frozen AlexNet parameter size')
    args.output_dir.mkdir(parents=True,exist_ok=True)
    (args.output_dir/'weights_rs.bin').write_bytes(result)
    (args.output_dir/'parameters_board.bin').write_bytes(parameters)
    manifest={'layout':'N_HCW_for_conv_NK_for_FC','layers':layers,
              'weights':{'file':'weights_rs.bin','bytes':len(result),'sha256':hashlib.sha256(result).hexdigest()},
              'parameters':{**source['parameters'],'file':'parameters_board.bin'},
              'source_manifest_sha256':hashlib.sha256(args.board_manifest.read_bytes()).hexdigest()}
    for key in ['source','source_url','checkpoint_sha256','quantization_contract',
                'quantization_contract_sha256','input_scale','output_scale','categories']:
        if key in source: manifest[key]=source[key]
    (args.output_dir/'rs_manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(f'RS row streaming weights: {len(result):,} bytes, unchanged numerical parameters')

if __name__=='__main__': main()
