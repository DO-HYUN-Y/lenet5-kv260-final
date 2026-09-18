"""Replay the RS input-row buffer and audit executed RS/hybrid RTL schedules.

Descriptor and AXI-Stream byte counts are not physical DDR burst measurements.
The input-buffer replay predicts the exact production gather policy and is
cross-checked against the complete trained-model RTL simulation.
"""
from __future__ import annotations
import argparse
from collections import defaultdict
import csv
import hashlib
import json
from pathlib import Path

GEOMETRY = [(3,224,11,4,2,64,55),(64,27,5,1,2,192,27),
 (192,13,3,1,1,384,13),(384,13,3,1,1,256,13),(256,13,3,1,1,256,13),
 (256,6,6,1,0,4096,1),(4096,1,1,1,0,4096,1),(4096,1,1,1,0,1000,1)]
NAMES=['conv1','conv2','conv3','conv4','conv5','fc6','fc7','fc8']

def predict_rs() -> list[dict]:
    result=[]
    for layer,(c,h,rw,stride,pad,n,ow) in enumerate(GEOMETRY,1):
        kt=c*rw*rw if layer<=5 else 9216 if layer==6 else 4096
        t=defaultdict(int)
        for oy in range(ow):
            for ox in range(0,ow,8):
                mc=min(8,ow-ox)
                for ko in range(0,kt,128*rw):
                    kc=min(128*rw,kt-ko);cache=set();key=None
                    t['input_tiles']+=1;t['input_valid_bytes']+=mc*kc
                    t['commands']+=(n+7)//8;t['weight_axis_bytes']+=n*kc
                    t['useful_macs']+=mc*n*kc
                    if ko: t['psum_read_valid_bytes']+=mc*n*4
                    if ko+kc<kt:t['psum_write_valid_bytes']+=mc*n*4
                    else:t['parameter_requested_bytes']+=((n+7)//8)*128
                    # Match the production row buffer: one channel group /
                    # input row, 39 strip positions or FC6's 36 positions.
                    for k in range(ko,ko+kc):
                        for m in range(mc):
                            if layer<=5:
                                row,kx=divmod(k,rw);ky,ch=divmod(row,c)
                                sy=oy*stride+ky-pad;sx=(ox+m)*stride+kx-pad
                                if not (0<=sy<h and 0<=sx<h):continue
                                next_key=(ch//8,sy);index=m*stride+kx
                            elif layer==6:
                                ch,index=divmod(k,36);next_key=(ch//8,0)
                            else:next_key=(k//8,0);index=0
                            if next_key!=key:cache.clear();key=next_key
                            if index not in cache:
                                cache.add(index);t['gather_requested_bytes']+=8
                # All reductions complete before this M tile is replaced.
        t['name']=NAMES[layer-1]
        t['pool_read_axis_bytes']=ow*ow*n if layer in (1,2,5) else 0
        ph=(ow-3)//2+1
        t['main_write_axis_bytes']=ow*ow*n+(ph*ph*n if layer in (1,2,5) else 0)
        t['main_read_axis_bytes']=t['gather_requested_bytes']+t['parameter_requested_bytes']+t['pool_read_axis_bytes']
        t['scratch_capacity_bytes']=min(8,ow)*n*4
        result.append(dict(t))
    assert sum(t['useful_macs'] for t in result)==714188480
    assert sum(t['commands'] for t in result)==56104
    assert sum(t['input_tiles'] for t in result)==1305
    return result

def audit_trace(path: Path,pure_rs: bool) -> list[dict]:
    totals=[defaultdict(int) for _ in GEOMETRY];coverage=defaultdict(list);tiles=set()
    with path.open(newline='') as f:
        for row in csv.DictReader(f):
            r={k:int(v) for k,v in row.items()}
            l,m,mc,n,nc,k,kc=(r[x] for x in ['layer','m_base','m_count','n_base','n_count','k_offset','k_count'])
            c,h,rw,stride,pad,nt,ow=GEOMETRY[l-1];mt=ow*ow
            kt=c*rw*rw if l<=5 else 9216 if l==6 else 4096
            assert 0<=m<m+mc<=mt and 0<=n<n+nc<=nt and 0<=k<k+kc<=kt
            t=totals[l-1];t['commands']+=1;t['useful_macs']+=mc*nc*kc
            coverage[l,m,n].append((k,kc,mc,nc))
            if pure_rs:
                assert mc<=8 and nc<=8 and kc<=128*rw
                assert k%rw==0 and kc%rw==0 and m%ow+mc<=ow
                assert r['first_k']==(k==0) and r['final_k']==(k+kc==kt)
                t['weight_transfer_bytes']+=nc*kc
                if (l,m,k) not in tiles:
                    tiles.add((l,m,k));t['input_valid_bytes']+=mc*kc;t['input_tiles']+=1
                if k:t['psum_read_valid_bytes']+=mc*nc*4
                if k+kc<kt:t['psum_write_valid_bytes']+=mc*nc*4
            else:
                if r['weight_fill']:t['weight_transfer_bytes']+=((nc+15)//16)*16*kc
                t['input_valid_bytes']+=mc*kc
    areas=defaultdict(int)
    for (l,m,n),chunks in coverage.items():
        next_k=0;mc,nc=chunks[0][2:]
        for k,kc,mcount,ncount in sorted(chunks):
            assert k==next_k and (mcount,ncount)==(mc,nc);next_k+=kc
        c,h,rw,s,p,nt,ow=GEOMETRY[l-1]
        assert next_k==(c*rw*rw if l<=5 else 9216 if l==6 else 4096)
        areas[l]+=mc*nc
    for l,t in enumerate(totals,1):
        assert areas[l]==GEOMETRY[l-1][5]*GEOMETRY[l-1][6]**2
        t['name']=NAMES[l-1]
    assert sum(t['useful_macs'] for t in totals)==714188480
    return [dict(t) for t in totals]

def main():
    root=Path(__file__).resolve().parent
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--trace-dir',type=Path,default=root/'build/rs_regression')
    p.add_argument('--output-dir',type=Path,default=root/'reports')
    args=p.parse_args();predicted=predict_rs()
    rs_path=args.trace_dir/'pure_rs_schedule.csv';hybrid_path=args.trace_dir/'hybrid_schedule.csv'
    rs=audit_trace(rs_path,True);hybrid=audit_trace(hybrid_path,False)
    for a,b in zip(rs,predicted):
        for key in ['commands','input_tiles','input_valid_bytes','useful_macs']:
            assert a[key]==b[key],(a['name'],key)
        assert a['weight_transfer_bytes']==b['weight_axis_bytes']
    rs_w=sum(t['weight_transfer_bytes'] for t in rs);hybrid_w=sum(t['weight_transfer_bytes'] for t in hybrid)
    assert (rs_w,hybrid_w)==(156334784,61123264)
    result={'source_commit':'854adea4d30e7861eae07f56df8f35966af31eb3',
      'scope':'executed RTL scheduler descriptors and independent RS gather-policy replay',
      'physical_ddr_measured':False,'pure_rs':rs,'github_hybrid':hybrid,'rs_gather_policy_prediction':predicted,
      'trace_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [rs_path,hybrid_path]},
      'weight_bytes':{'pure_rs':rs_w,'hybrid':hybrid_w,'hybrid_reduction_percent':100*(rs_w-hybrid_w)/rs_w},
      'memory_budget':{'shared_input_bank_bytes':131072,'shared_output_bank_bytes':8192,
        'external_psum_scratch_bytes':16384,'psum_ddr_spill_bytes':0,'weight_uram_bytes':0,
        'unique_filter_row_rf_max_bytes':128*11,'input_union_row_rf_allocated_bytes':512*16,
        'local_row_psum_payload_bits':512*2*19,'gather_row_buffer_payload_bytes':39*8},
      'limits':['Weight-component savings do not alone establish total physical DDR savings or speed.',
        'RS has additional row register storage; DSP count and shared bank capacities are fixed, total FF/LUT area is reported separately.',
        'Gather predictions describe RS row-buffer policy; no hybrid physical input-traffic measurement is claimed.',
        'M tiles stop at output row boundaries; this increases RS Conv weight loads relative to cross-row M8 tiling.']}
    args.output_dir.mkdir(parents=True,exist_ok=True)
    (args.output_dir/'traffic.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['# Pure RS / hybrid traffic audit','',result['scope']+'. Physical DDR has not been measured.','',
      '| Layer | RS weight B | Hybrid weight B | RS raw gather B |','|---|---:|---:|---:|']
    for a,b,c in zip(rs,hybrid,predicted):lines.append(f"| {a['name']} | {a['weight_transfer_bytes']:,} | {b['weight_transfer_bytes']:,} | {c['gather_requested_bytes']:,} |")
    lines+=['',f'Weight component: RS {rs_w:,} B, hybrid {hybrid_w:,} B; hybrid reduction {result["weight_bytes"]["hybrid_reduction_percent"]:.2f}%.',
      '', 'The 16 KiB external psum scratch serves continuation on chip; no artificial psum DDR spill is counted.',
      '',*result['limits']]
    (args.output_dir/'traffic.md').write_text('\n'.join(lines)+'\n')
    print(json.dumps(result['weight_bytes']))
if __name__=='__main__':main()
