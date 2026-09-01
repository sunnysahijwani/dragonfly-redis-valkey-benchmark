#!/usr/bin/env python3
"""Generate the blog images (OG cover + one hero image per post) from the real
capture in results/runs-aws.csv. Output: blog/images/*.png (1200x630, OG size)."""
import csv, os, statistics
from collections import defaultdict
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "blog", "images"); os.makedirs(OUT, exist_ok=True)
ROWS = list(csv.DictReader(open(os.path.join(ROOT, "results", "runs-aws.csv"))))
CORES = [4, 8, 16, 24, 48]

# palette
DF="#059669"; RR="#ef4444"; RC="#7f1d1d"; VR="#a78bfa"; VC="#6d28d9"
INK="#0f172a"; MUT="#64748b"; BG="#ffffff"
plt.rcParams.update({"font.family":"DejaVu Sans","font.size":13,"axes.edgecolor":"#cbd5e1",
    "axes.grid":True,"grid.color":"#e2e8f0","grid.linewidth":.8,"figure.dpi":100})

def med(vs):
    vs=[float(v) for v in vs if v not in ("",None)]; return statistics.median(vs) if vs else 0.0
def sel(ratio,data,pipe):
    return [r for r in ROWS if r["ratio"]==ratio and r["data_bytes"]==data and r["pipeline"]==pipe]
def curve(rows):
    by=defaultdict(lambda: defaultdict(list))
    for r in rows: by[f'{r["engine"]}-{r["mode"]}'][int(r["cores_used"])].append(float(r["ops_per_sec"]))
    return by
def fig():
    f,ax=plt.subplots(figsize=(12,6.3)); f.patch.set_facecolor(BG); ax.set_facecolor(BG); return f,ax
def foot(ax): ax.annotate("c7i.metal-24xl · 48 cores · Redis 8.2.8 / Valkey 8.1.9 / Dragonfly 1.40.1 · io_uring · memtier client-side latency",
    xy=(0,-0.16), xycoords="axes fraction", fontsize=9, color=MUT)
def save(f,name): f.tight_layout(); f.savefig(os.path.join(OUT,name),bbox_inches="tight",facecolor=BG); plt.close(f); print("wrote",name)
def M(x,_=None): return f"{x:.0f}M"

by=curve(sel("1:10","100","16"))
df48=med(by["dragonfly-single"].get(48,[0]))/1e6
rr48=med(by["redis-cluster"].get(48,[0]))/1e6
rc48=med(by["redis-cluster-sat"].get(48,[0]))/1e6

# ---------- OG COVER ----------
f,ax=plt.subplots(figsize=(12,6.3)); f.patch.set_facecolor(INK); ax.set_facecolor(INK); ax.axis("off")
ax.text(.5,.90,"Dragonfly vs Redis vs Valkey",ha="center",fontsize=34,color="white",weight="bold",transform=ax.transAxes)
ax.text(.5,.80,"Throughput, scaling & the operational-simplicity trade-off on 48 real cores",
    ha="center",fontsize=15,color="#cbd5e1",transform=ax.transAxes)
trip=[("Dragonfly\n(one process)",f"{df48:.1f}M",DF),("Redis Cluster\n(normal client)",f"{rr48:.1f}M","#f87171"),
      ("Redis Cluster\n(driven perfectly)",f"{rc48:.1f}M","#fca5a5")]
for i,(lbl,num,c) in enumerate(trip):
    x=.19+i*.31
    ax.text(x,.50,num,ha="center",fontsize=44,color=c,weight="bold",transform=ax.transAxes)
    ax.text(x,.36,lbl,ha="center",fontsize=13,color="#e2e8f0",transform=ax.transAxes)
    ax.text(x,.28,"ops/sec",ha="center",fontsize=11,color=MUT,transform=ax.transAxes)
ax.text(.5,.12,"Same hardware. Read-heavy, pipelined. All three numbers are real.",
    ha="center",fontsize=13,color="#94a3b8",style="italic",transform=ax.transAxes)
ax.text(.5,.04,"two-techies.com  ·  reproducible harness + raw data",ha="center",fontsize=10,color=MUT,transform=ax.transAxes)
f.savefig(os.path.join(OUT,"og-cover.png"),bbox_inches="tight",facecolor=INK); plt.close(f); print("wrote og-cover.png (dark)")

# ---------- 01 methodology: three configs (48c bars) ----------
f,ax=fig()
labels=["Dragonfly\n(one process)","Redis cluster\n(realistic client)","Redis cluster\n(fully driven)"]
vals=[df48,rr48,rc48]; cols=[DF,RR,RC]
b=ax.bar(labels,vals,color=cols,width=.6)
for r,v in zip(b,vals): ax.text(r.get_x()+r.get_width()/2,v+.6,f"{v:.1f}M",ha="center",fontsize=15,weight="bold",color=INK)
ax.set_ylabel("ops / sec (millions)"); ax.set_title("We measured three things, not two — 48 cores, read-heavy, pipelined",
    fontsize=16,weight="bold",color=INK,loc="left")
ax.yaxis.set_major_formatter(FuncFormatter(M)); foot(ax); save(f,"01-methodology.png")

# ---------- 02 scaling line ----------
f,ax=fig()
def line(series,color,label,ls="-",lw=2.8,alpha=1):
    ys=[med(by[series].get(c,[0]))/1e6 for c in CORES]; ax.plot(CORES,ys,ls,color=color,lw=lw,alpha=alpha,marker="o",ms=6,label=label); return ys
line("redis-cluster-sat",RC,"Redis cluster — fully-driven ceiling",ls="--")
line("valkey-cluster-sat",VC,"Valkey cluster — ceiling",ls="--",lw=1.6,alpha=.5)
dfy=line("dragonfly-single",DF,"Dragonfly (one process)")
line("redis-cluster",RR,"Redis cluster — realistic client")
line("valkey-cluster",VR,"Valkey cluster — realistic",lw=1.6,alpha=.5)
ax.set_xticks(CORES); ax.set_xlabel("server cores"); ax.set_ylabel("ops / sec (millions)")
ax.set_title("Scaling: three completely different shapes",fontsize=16,weight="bold",color=INK,loc="left")
ax.yaxis.set_major_formatter(FuncFormatter(M)); ax.legend(fontsize=11,loc="upper left",framealpha=.9)
ax.annotate("Dragonfly overtakes the\nrealistic cluster ~16 cores",xy=(16,med(by["dragonfly-single"].get(16,[0]))/1e6),
    xytext=(20,9),fontsize=10,color=MUT,arrowprops=dict(arrowstyle="->",color=MUT))
foot(ax); save(f,"02-scaling.png")

# ---------- 03 saturation: same cluster, two clients ----------
f,ax=fig()
b=ax.bar(["Redis cluster\nnormal client","Redis cluster\none client per shard"],[rr48,rc48],color=[RR,RC],width=.55)
for r,v in zip(b,[rr48,rc48]): ax.text(r.get_x()+r.get_width()/2,v+.6,f"{v:.1f}M",ha="center",fontsize=16,weight="bold",color=INK)
ax.axhline(df48,color=DF,ls="--",lw=2); ax.text(1.45,df48,f"Dragonfly {df48:.1f}M",color=DF,va="center",fontsize=12,weight="bold")
ax.set_ylabel("ops / sec (millions)")
ax.set_title("Same 48-shard cluster, same hardware — only the client changed",fontsize=16,weight="bold",color=INK,loc="left")
ax.annotate("shards were only ~16% busy\nuntil the client changed",xy=(0,rr48),xytext=(.3,20),fontsize=11,color=MUT,
    arrowprops=dict(arrowstyle="->",color=MUT)); ax.yaxis.set_major_formatter(FuncFormatter(M)); foot(ax); save(f,"03-saturation.png")

# ---------- 04 latency (log) ----------
f,ax=fig()
import numpy as np
def lat(series,pipe="16"):
    rs=[r for r in sel("1:10","100",pipe) if f'{r["engine"]}-{r["mode"]}'==series and int(r["cores_used"])==48]
    return [med([r["p50_ms"] for r in rs]),med([r["p99_ms"] for r in rs]),med([r["p999_ms"] for r in rs])]
groups=["p50","p99","p99.9"]; x=np.arange(3); w=.25
for i,(s,c,l) in enumerate([("dragonfly-single",DF,"Dragonfly"),("redis-cluster-sat",RC,"Redis cluster (driven well)"),("redis-cluster",RR,"Redis cluster (normal client)")]):
    v=lat(s); bars=ax.bar(x+(i-1)*w,v,w,color=c,label=l)
    for r,val in zip(bars,v): ax.text(r.get_x()+r.get_width()/2,val*1.1,f"{val:g}",ha="center",fontsize=9,color=INK)
ax.set_yscale("log"); ax.set_xticks(x); ax.set_xticklabels(groups); ax.set_ylabel("latency (ms, log scale)")
ax.set_title("Latency under load — 48 cores, read-heavy, pipelined",fontsize=16,weight="bold",color=INK,loc="left")
ax.legend(fontsize=11); foot(ax); save(f,"04-latency.png")

# ---------- 05 memory ----------
f,ax=fig()
mem={"Dragonfly":146.1,"Redis 8.2":165.3,"Valkey 8.1":168.7}
b=ax.bar(list(mem),list(mem.values()),color=[DF,RR,VC],width=.55)
for r,v in zip(b,mem.values()): ax.text(r.get_x()+r.get_width()/2,v+1.5,f"{v}",ha="center",fontsize=15,weight="bold",color=INK)
ax.set_ylabel("bytes / key  (1M keys × 100B, baseline-subtracted)")
ax.set_title("Memory efficiency — Dragonfly ~13% leaner (hardware-independent)",fontsize=16,weight="bold",color=INK,loc="left")
ax.set_ylim(0,190); foot(ax); save(f,"05-memory.png")

# ---------- 06 multi-key ----------
f,ax=fig()
mk=curve([r for r in ROWS if r["ratio"]=="mget10" and r["data_bytes"]=="100" and r["pipeline"]=="16"])
ys=[med(mk["dragonfly-single"].get(c,[0]))/1e6 for c in CORES]
ax.plot(CORES,ys,color=DF,lw=2.8,marker="o",ms=7,label="Dragonfly — MGET(10)")
ax.set_xticks(CORES); ax.set_xlabel("server cores"); ax.set_ylabel("commands / sec (millions)")
ax.set_title("Multi-key across the whole keyspace — Dragonfly scales; clusters can't",fontsize=15,weight="bold",color=INK,loc="left")
ax.text(0.5,0.42,"Redis / Valkey cluster:\ncross-slot MGET → CROSSSLOT ✗\n(no bar possible)",transform=ax.transAxes,
    fontsize=13,color=RR,ha="center",bbox=dict(boxstyle="round,pad=.5",fc="#fef2f2",ec=RR))
ax.legend(fontsize=12,loc="upper left"); foot(ax); save(f,"06-multikey.png")

# ---------- 07 decision radar ----------
import numpy as np
f=plt.figure(figsize=(12,6.3)); f.patch.set_facecolor(BG)
ax=f.add_subplot(111,polar=True); ax.set_facecolor(BG)
axes_lbl=["Throughput\n(normal client)","Operational\nsimplicity","Multi-key /\ntxns","Memory\nefficiency","Small failure\ndomain / HA","Raw throughput\nceiling"]
df_s=[5,5,5,4,2,3]; cl_s=[2,2,1,3,5,5]
N=len(axes_lbl); ang=np.linspace(0,2*np.pi,N,endpoint=False).tolist(); ang+=ang[:1]
for vals,c,lab in [(df_s,DF,"Dragonfly (single node)"),(cl_s,RR,"Redis/Valkey Cluster")]:
    v=vals+vals[:1]; ax.plot(ang,v,color=c,lw=2.5,label=lab); ax.fill(ang,v,color=c,alpha=.12)
ax.set_xticks(ang[:-1]); ax.set_xticklabels(axes_lbl,fontsize=11); ax.set_yticks([1,2,3,4,5]); ax.set_yticklabels([],fontsize=8); ax.set_ylim(0,5)
f.suptitle("When to use which — the three-way trade-off",fontsize=17,weight="bold",color=INK,y=1.06)
ax.legend(loc="lower center",bbox_to_anchor=(0.5,-0.14),ncol=2,fontsize=12,frameon=False)
f.savefig(os.path.join(OUT,"07-decision.png"),bbox_inches="tight",facecolor=BG); plt.close(f); print("wrote 07-decision.png")
print("\nAll images in blog/images/")
