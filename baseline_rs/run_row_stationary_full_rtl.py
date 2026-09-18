"""Compile and run the complete pure RS RTL using Verilator's timing simulator.

Requires a Verilator executable and generated rs_trained_vectors. Uses the
production RTL without replacing the SA. DMA and external DDR are testbench
services; PS registers have separate component tests; physical DDR timing requires a board.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import time

SOURCES = [
    'packed_mac/alexnet_row_stationary_pe.sv', 'packed_mac/alexnet_rs_filter_row_rf.sv', 'sa/alexnet_sa_m8r128_row_stationary.sv',
    'postprocess/alexnet_n8_requant.sv', 'postprocess/alexnet_m8n8_parallel_requant.sv',
    'postprocess/alexnet_m8n8_requant_serializer.sv', 'result/alexnet_n8_output_router.sv',
    'control/alexnet_row_stationary_graph_scheduler.sv',
    'integration/alexnet_m8r128_row_stationary_core.sv',
    'integration/alexnet_row_stationary_graph_engine.sv',
    'memory/alexnet_m16_patch_pingpong.sv', 'memory/alexnet_n8_activation_bank.sv',
    'memory/alexnet_n8_activation_pingpong.sv', 'memory/alexnet_m8n8_int32_partial_sum_bank.sv',
    'memory/alexnet_row_stationary_psum_scratch.sv',
    'dma/alexnet_row_stationary_weight_dma_bridge.sv',
    'integration/alexnet_row_stationary_banked_engine.sv',
    'feeder/alexnet_row_stationary_gather.sv', 'dma/alexnet_parameter_record_loader.sv',
    'dma/alexnet_axis128_to_n8_unpacker.sv', 'dma/alexnet_n8_to_axis128_packer.sv',
    'pool/alexnet_n8_maxpool3x3.sv', 'integration/alexnet_conv_result_pool_service.sv',
    'integration/alexnet_m8n126_inplace_pool_service.sv',
    'integration/alexnet_row_stationary_ddr_engine.sv']


def validate_vectors(manifest: dict, vector_root: Path) -> dict:
    vectors = json.loads((vector_root/'manifest.json').read_text())
    for key in ('weights', 'parameters'):
        vector_key = 'trained_weights_sha256' if key == 'weights' else 'parameters_sha256'
        if vectors.get(vector_key) != manifest[key]['sha256']:
            raise ValueError('Vectors were generated for a different frozen model')
    expected = {'input', 'conv1', 'conv2', 'conv3', 'conv4', 'conv5',
                'fc6', 'fc7', 'fc8', 'pool1', 'pool2', 'pool5'}
    if set(vectors.get('full_tensors', {})) != {name+'_n8.bin' for name in expected}:
        raise ValueError('Vector manifest is incomplete; regenerate the numerical vectors')
    for name, record in vectors['full_tensors'].items():
        data = (vector_root/name).read_bytes()
        if len(data) != record['bytes'] or hashlib.sha256(data).hexdigest() != record['sha256']:
            raise ValueError('Golden tensor differs from vector manifest: '+name)
    return vectors


def main():
    root = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verilator', default=shutil.which('verilator'))
    parser.add_argument('--model-root', type=Path, required=True)
    parser.add_argument('--vector-root', type=Path, default=root/'build/rs_trained_vectors')
    parser.add_argument('--build-dir', type=Path, default=root/'build/rs_full_verilator')
    parser.add_argument('--output-dir', type=Path, default=root/'reports')
    parser.add_argument('--jobs',type=int,default=4)
    parser.add_argument('--reuse-build',action='store_true')
    args = parser.parse_args()
    if not args.verilator:
        parser.error('Install Verilator or provide --verilator /path/to/verilator')
    manifest = json.loads((args.model_root/'rs_manifest.json').read_text())
    for key in ('weights','parameters'):
        record = manifest[key]; data = (args.model_root/record['file']).read_bytes()
        if hashlib.sha256(data).hexdigest()!=record['sha256'] or len(data)!=record['bytes']:
            parser.error('Model file differs from frozen manifest: '+key)
    if not (args.vector_root/'manifest.json').exists():
        parser.error('Generate vectors with validate_row_stationary_inference.py first')
    try:
        vectors = validate_vectors(manifest, args.vector_root)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    args.build_dir.mkdir(parents=True,exist_ok=True)
    args.output_dir.mkdir(parents=True,exist_ok=True)
    build = args.build_dir.resolve()
    sources = [root/'rtl'/s if (root/'rtl'/s).exists() else root.parent/'alexnet/rtl'/s for s in SOURCES]+[root/'tb/tb_alexnet_row_stationary_full.sv']
    hashes = {str(p.relative_to(root.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    recorded = build/'source_hashes.json'
    binary = build/'Vtb_alexnet_row_stationary_full'
    if args.reuse_build and (not binary.exists() or not recorded.exists() or json.loads(recorded.read_text())!=hashes):
        parser.error('Compiled model is missing or stale; run without --reuse-build')
    if not args.reuse_build:
        command = [args.verilator,'--binary','--timing','--assert','-Wno-fatal','-O3',
                   '--top-module','tb_alexnet_row_stationary_full','--Mdir',str(build),
                   '--output-split','20000','--output-split-cfuncs','500','-j',str(args.jobs),
                   '-CFLAGS','-O3']+[str(p) for p in sources]
        with (build/'compile.log').open('w') as log:
            subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
        recorded.write_text(json.dumps(hashes,indent=2)+'\n')
    output = (args.output_dir/'full_rtl_validation.json').resolve()
    output.unlink(missing_ok=True)  # A failed run cannot leave a stale PASS.
    started = time.monotonic()
    # Keep layer progress visible when the simulator writes to a regular log.
    line_buffer = [shutil.which('stdbuf'), '-oL'] if shutil.which('stdbuf') else []
    with (build/'run.log').open('w') as log:
        subprocess.run(line_buffer+[str(binary),'+vector_root='+str(args.vector_root.resolve()),
                        '+model_root='+str(args.model_root.resolve()),'+report='+str(output)],
                       check=True,stdout=log,stderr=subprocess.STDOUT)
    run_log = (build/'run.log').read_text()
    if 'ALEXNET_ROW_STATIONARY_FULL_RTL_TEST_PASSED' not in run_log:
        raise RuntimeError('Full RTL PASS marker missing')
    report = json.loads(output.read_text())
    from audit_row_stationary_traffic import predict_rs
    predicted=predict_rs()
    for key in ('commands','input_tiles','useful_macs','main_read_axis_bytes',
                'main_write_axis_bytes','weight_axis_bytes','gather_requested_bytes'):
        expected=sum(layer.get(key,0) for layer in predicted)
        if report.get(key)!=expected:raise RuntimeError(f'RS traffic mismatch {key}: {report.get(key)} != {expected}')
    report['independent_gather_and_schedule_prediction_matches']=True
    report.update(elapsed_seconds=time.monotonic()-started, rtl_source_sha256=hashes,
                  trained_weights_sha256=manifest['weights']['sha256'],
                  input_seed=json.loads((args.vector_root/'manifest.json').read_text())['input_seed'],
                  input_n8_sha256=hashlib.sha256((args.vector_root/'input_n8.bin').read_bytes()).hexdigest(),
                  golden_tensor_records=vectors['full_tensors'],
                  whole_network_rtl_numerical_inference_verified=True,
                  physical_board_inference_verified=False,
                  verilator_version=subprocess.check_output([args.verilator,'--version'],text=True).strip())
    output.write_text(json.dumps(report,indent=2)+'\n')
    print(run_log)


if __name__=='__main__':
    main()
