"""Frozen trained-model full numerical RS replay against original C++ golden.

Uses stdlib, CMake and C++; no torch/download/requantization. This is a full
software numerical check. Exported tile vectors and full tensor binaries also
drive separate actual RTL tests; this report records the software check only.
"""
from __future__ import annotations

import argparse
import ctypes as ct
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import time

I8P = ct.POINTER(ct.c_int8)
I32P = ct.POINTER(ct.c_int32)
U8P = ct.POINTER(ct.c_uint8)
GEOMETRY = [(3,224,11,4,2,64,55), (64,27,5,1,2,192,27),
            (192,13,3,1,1,384,13), (384,13,3,1,1,256,13),
            (256,13,3,1,1,256,13), (256,6,1,1,0,4096,1),
            (4096,1,1,1,0,4096,1), (4096,1,1,1,0,1000,1)]
NAMES = ['conv1', 'conv2', 'conv3', 'conv4', 'conv5', 'fc6', 'fc7', 'fc8']


def i8(data: bytes):
    return (ct.c_int8 * len(data)).from_buffer_copy(data)


def chw_to_n8(data, c: int, spatial: int):
    result = (ct.c_int8 * (((c+7)//8)*spatial*8))()
    for channel in range(c):
        for m in range(spatial):
            result[((channel//8)*spatial+m)*8+channel%8] = data[channel*spatial+m]
    return result


def n8_to_chw(data, c: int, spatial: int):
    result = (ct.c_int8 * (c*spatial))()
    for channel in range(c):
        for m in range(spatial):
            result[channel*spatial+m] = data[((channel//8)*spatial+m)*8+channel%8]
    return result


def configure_golden(path: Path):
    lib = ct.CDLL(str(path))
    conv_args = [I8P] + [ct.c_int]*4 + [I8P] + [ct.c_int]*11
    for suffix, args in [('accumulate', [I32P, ct.c_int]),
                         ('int8', [I32P, I32P, U8P, ct.c_uint8, I8P, ct.c_int])]:
        fun = getattr(lib, 'alexnet_golden_conv2d_'+suffix)
        fun.argtypes = conv_args+args
        fun.restype = ct.c_int
    lib.alexnet_golden_linear_accumulate.argtypes = [I8P, ct.c_int, ct.c_int, I8P, ct.c_int, I32P, ct.c_int]
    lib.alexnet_golden_linear_int8.argtypes = [I8P, ct.c_int, ct.c_int, I8P, ct.c_int, I32P, I32P, U8P, ct.c_uint8, I8P, ct.c_int]
    lib.alexnet_golden_maxpool2d.argtypes = [I8P]+[ct.c_int]*10+[I8P, ct.c_int]
    return lib


def export_tile(folder: Path, layer: int, source, weights: bytes, params: bytes,
                output, acc, geometry):
    c, h, kernel, stride, pad, n, ow = geometry
    kt = c*kernel*kernel if layer<=5 else 9216 if layer==6 else 4096
    mc = min(8,ow*ow)
    folder.mkdir(parents=True, exist_ok=True)
    resident = [[0]*kt for _ in range(mc)]
    for m in range(mc):
        for k in range(kt):
            if layer<=5:
                row, kx = divmod(k,kernel)
                ky,channel=divmod(row,c)
                y = m//ow*stride+ky-pad
                x = m%ow*stride+kx-pad
                value = source[((channel//8)*h*h+y*h+x)*8+channel%8] if 0<=y<h and 0<=x<h else 0
            elif layer==6:
                channel, position = divmod(k,36)
                value = source[((channel//8)*36+position)*8+channel%8]
            else:
                value = source[k]
            resident[m][k] = value
    (folder/'input.hex').write_text(''.join(f'{sum((resident[m][k]&255)<<(m*8) for m in range(mc)):016x}\n' for k in range(kt)))
    (folder/'weights.hex').write_text(''.join(f'{b:02x}\n' for b in weights[:8*kt]))
    (folder/'parameters.hex').write_text(''.join(f'{int.from_bytes(params[n*16:(n+1)*16],"little"):032x}\n' for n in range(8)))
    (folder/'output.hex').write_text(''.join(f'{sum((output[m*8+nl]&255)<<(nl*8) for nl in range(8)):016x}\n' for m in range(mc)))
    previous = [[0]*mc for _ in range(8)]
    partials = []
    block=128*(kernel if layer<=5 else 6 if layer==6 else 1)
    for ko in range(0,kt,block):
        for nl in range(8):
            for m in range(8):
                if m < mc:
                    previous[nl][m] += sum(resident[m][k]*ct.c_int8(weights[nl*kt+k]).value for k in range(ko,min(ko+block,kt)))
                    value = previous[nl][m]
                else:
                    value = 0
                partials.append(f'{value&0xffffffff:08x}\n')
    for nl in range(8):
        for m in range(mc):
            assert previous[nl][m] == acc[m*8+nl]
    (folder/'partial.hex').write_text(''.join(partials))


def run(rs_manifest: Path, board_manifest: Path, output_dir: Path, vector_dir: Path, seed: int = 7):
    root = Path(__file__).resolve().parent
    build = root/'build/rs_numerical_golden'
    subprocess.run(['cmake', '-S', str(root.parent/'alexnet/cpp'), '-B', str(build), '-DCMAKE_BUILD_TYPE=Release'], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['cmake', '--build', str(build), '-j', '4', '--target', 'alexnet_golden_dpi'], check=True, stdout=subprocess.DEVNULL)
    mirror_path = build/'librow_stationary_numerical.so'
    subprocess.run(['g++', '-std=c++17', '-O3', '-Wall', '-Wextra', '-Werror', '-fPIC', '-shared',
                    str(root/'cpp/row_stationary_ref.cpp'), '-o', str(mirror_path)], check=True)
    golden = configure_golden((build/'libalexnet_golden_dpi.so').resolve())
    mirror = ct.CDLL(str(mirror_path.resolve()))
    mirror.alexnet_row_stationary_layer.argtypes = [I8P,I8P,I32P,I32P,U8P,ct.c_int,ct.c_int,I8P,I32P,ct.POINTER(ct.c_uint64)]
    manifest = json.loads(rs_manifest.read_text())
    original = json.loads(board_manifest.read_text())
    packed = (rs_manifest.parent/manifest['weights']['file']).read_bytes()
    parameters = (rs_manifest.parent/manifest['parameters']['file']).read_bytes()
    for blob, record in [(packed,manifest['weights']), (parameters,manifest['parameters'])]:
        assert len(blob)==record['bytes'] and hashlib.sha256(blob).hexdigest()==record['sha256']
    # Reproducible signed INT8 input; a numerical stress vector, not an image
    # dataset or an accuracy evaluation. Include negative activations.
    value = i8(bytes((((c*11+y*19+x*7+seed*(x//9-y//7))%127)-63)&255
                     for c in range(3) for y in range(224) for x in range(224)))
    source = chw_to_n8(value,3,224*224)
    vector_dir.mkdir(parents=True,exist_ok=True)
    (vector_dir/'input_n8.bin').write_bytes(bytes(source))
    input_sha = hashlib.sha256(bytes(value)).hexdigest()
    results, total_macs, total_commands, total_tiles = [], 0, 0, 0
    start = time.monotonic()
    for layer, (name, geometry) in enumerate(zip(NAMES,GEOMETRY), 1):
        c,h,kernel,stride,pad,n,ow = geometry
        record = manifest['layers'][name]
        kt = record['k']
        weights = packed[record['offset']:record['offset']+record['bytes']]
        logical_record = original['layers'][name]
        logical_path = board_manifest.parent/logical_record['logical_file']
        logical_blob = logical_path.read_bytes()
        assert hashlib.sha256(logical_blob).hexdigest()==logical_record['logical_sha256']
        logical = i8(logical_blob)
        params = parameters[record['parameter_offset']:record['parameter_offset']+n*16]
        biases, multipliers, shifts = [], [], []
        for b,m,s,relu,padding in struct.iter_unpack('<iiBB6s',params):
            assert padding==bytes(6) and relu==(layer!=8)
            biases.append(b); multipliers.append(m); shifts.append(s)
        bias = (ct.c_int32*n)(*biases); mul = (ct.c_int32*n)(*multipliers); shift = (ct.c_uint8*n)(*shifts)
        count = n*ow*ow
        reference = (ct.c_int8*count)(); reference_acc = (ct.c_int32*count)()
        if layer<=5:
            args = [value,1,c,h,h,logical,n,c,kernel,kernel,1,stride,stride,pad,pad,1,1]
            status = golden.alexnet_golden_conv2d_accumulate(*args,reference_acc,count)
            assert status==0,(name,status)
            status = golden.alexnet_golden_conv2d_int8(*args,bias,mul,shift,int(layer!=8),reference,count)
        else:
            status = golden.alexnet_golden_linear_accumulate(value,1,kt,logical,n,reference_acc,count)
            assert status==0,(name,status)
            status = golden.alexnet_golden_linear_int8(value,1,kt,logical,n,bias,mul,shift,int(layer!=8),reference,count)
        assert status==0,(name,status)
        actual = (ct.c_int8*count)(); actual_acc = (ct.c_int32*count)(); counters = (ct.c_uint64*5)()
        status = mirror.alexnet_row_stationary_layer(source,i8(weights),bias,mul,shift,int(layer!=8),layer,actual,actual_acc,counters)
        assert status==0,(name,'RS bounds/status',status)
        actual_chw = n8_to_chw(actual,n,ow*ow); acc_chw = n8_to_chw_int32(actual_acc,n,ow*ow)
        assert bytes(actual_chw)==bytes(reference),name+' output differs'
        assert bytes(acc_chw)==bytes(reference_acc),name+' accumulator differs'
        (vector_dir/(name+'_n8.bin')).write_bytes(bytes(actual))
        export_tile(vector_dir/name,layer,source,weights,params,actual,actual_acc,geometry)
        total_macs += counters[0]; total_commands += counters[3]; total_tiles += counters[4]
        results.append({'layer':name,'output_bytes':count,'output_sha256':hashlib.sha256(bytes(actual)).hexdigest(),
                        'accumulator_mismatches':0,'output_mismatches':0,'macs':counters[0],
                        'commands':counters[3],'input_tiles':counters[4],
                        'accumulator_min':min(actual_acc),'accumulator_max':max(actual_acc)})
        if layer in (1,2,5):
            ph = (ow-3)//2+1
            pooled = (ct.c_int8*(n*ph*ph))()
            status = golden.alexnet_golden_maxpool2d(reference,1,n,ow,ow,3,3,2,2,0,0,pooled,n*ph*ph)
            assert status==0
            rs_pool = (ct.c_int8*(n*ph*ph))()
            for channel in range(n):
                for y in range(ph):
                    for x in range(ph):
                        rs_pool[((channel//8)*ph*ph+y*ph+x)*8+channel%8] = max(
                            actual[((channel//8)*ow*ow+(y*2+dy)*ow+x*2+dx)*8+channel%8]
                            for dy in range(3) for dx in range(3))
            assert bytes(n8_to_chw(rs_pool,n,ph*ph))==bytes(pooled)
            pool_name = {1:'pool1',2:'pool2',5:'pool5'}[layer]
            (vector_dir/(pool_name+'_n8.bin')).write_bytes(bytes(rs_pool))
            results.append({'layer':{1:'pool1',2:'pool2',5:'pool5'}[layer],
                            'output_mismatches':0,'output_bytes':n*ph*ph,
                            'output_sha256':hashlib.sha256(bytes(rs_pool)).hexdigest()})
            value, source = pooled, rs_pool
        else:
            value, source = actual_chw, actual
        print(name+': accumulator/output PASS',flush=True)
    assert (total_macs,total_commands,total_tiles)==(714188480,56104,1305)
    report = {'scope':'full trained-model SOFTWARE row numerical replay plus exported RTL tile vectors',
              'whole_network_rtl_numerical_inference_verified':False,'physical_ddr_measured':False,
              'input_kind':'deterministic signed INT8 numerical vector','input_seed':seed,'input_sha256':input_sha,
              'trained_weights_sha256':manifest['weights']['sha256'],
              'quantization_contract_sha256':manifest['quantization_contract_sha256'],
              'layers':results,'useful_macs':total_macs,'commands':total_commands,'input_tiles':total_tiles,
              'elapsed_seconds':time.monotonic()-start,'all_accumulators_and_outputs_match':True,
              'signed19_to26_row_tree_and_signed27_continuation_postbias_checked':True,
              'numerical_model_source_sha256':hashlib.sha256((root/'cpp/row_stationary_ref.cpp').read_bytes()).hexdigest()}
    output_dir.mkdir(parents=True,exist_ok=True)
    (output_dir/'full_numerical_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    tensors = {p.name: {'bytes': p.stat().st_size,
                       'sha256': hashlib.sha256(p.read_bytes()).hexdigest()}
               for p in sorted(vector_dir.glob('*_n8.bin'))}
    (vector_dir/'manifest.json').write_text(json.dumps({
        'layers':NAMES,'input_seed':seed,'scope':report['scope'],
        'trained_weights_sha256':manifest['weights']['sha256'],
        'parameters_sha256':manifest['parameters']['sha256'],
        'full_tensors':tensors},indent=2)+'\n')
    return report


def n8_to_chw_int32(data,c,spatial):
    result = (ct.c_int32*(c*spatial))()
    for channel in range(c):
        for m in range(spatial):
            result[channel*spatial+m] = data[((channel//8)*spatial+m)*8+channel%8]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rs-manifest',type=Path,required=True)
    parser.add_argument('--board-manifest',type=Path,required=True)
    parser.add_argument('--output-dir',type=Path,default=Path('baseline_rs/reports'))
    parser.add_argument('--vector-dir',type=Path,default=Path('baseline_rs/build/rs_trained_vectors'))
    parser.add_argument('--seed',type=int,default=7)
    args = parser.parse_args()
    run(args.rs_manifest.resolve(),args.board_manifest.resolve(),args.output_dir.resolve(),args.vector_dir.resolve(),args.seed)


if __name__=='__main__':
    main()
