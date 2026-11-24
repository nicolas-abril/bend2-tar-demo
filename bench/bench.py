#!/usr/bin/env python3
# Times tar+gzip style commands on a corpus: wall (min/median of reps),
# CPU (user+sys of the whole tree), peak RSS of the largest process, output size.
# usage: bench.py GROUP REPS CORPUS_DIR OUT_JSON   (GROUP: create levels strong extract)
# env: BENDS="label=path/to/tar ..." (the Bend builds to compare), TWIN=path/to/tar-c,
#      WORK=scratch dir holding ref.tar/ref.tgz/ref.zst/ref.xz from prep.sh
import json, os, shutil, statistics, subprocess, sys, time

group, reps, corpus, out_json = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
BENDS = [tuple(b.split("=", 1)) for b in os.environ["BENDS"].split()]
TWIN = os.path.abspath(os.environ["TWIN"])
W = os.path.abspath(os.environ["WORK"])
os.makedirs(W, exist_ok=True)
files = " ".join(sorted(os.listdir(corpus)))
raw = sum(os.path.getsize(os.path.join(corpus, f)) for f in os.listdir(corpus))
TAR = "bsdtar -cf - " + files  # the tar step shared by every external compressor

def comp(name, cmd, out):
    return dict(name=name, cmd=cmd, out=out, cwd=corpus)

def bend(b, lvl="", thr=""):
    t = f"BENDRTS='--threads {thr}' " if thr else ""
    return f"{t}{os.path.abspath(b)} -cz{lvl}f {W}/o.tgz {files}"

G = {}
G["create"] = [
    comp(f"bend {n} -6", bend(p), "o.tgz") for n, p in BENDS
] + [
    comp(f"bend {n} -6 (1 thread)", bend(p, thr="1"), "o.tgz") for n, p in BENDS
] + [
    comp("C twin (tar.c) -6",       f"{TWIN} -czf {W}/o.tgz {files}", "o.tgz"),
    comp("bsdtar -czf (zlib -6)",   f"bsdtar -czf {W}/o.tgz {files}", "o.tgz"),
    comp("gzip -6",                 f"{TAR} | gzip -6 > {W}/o.gz", "o.gz"),
    comp("pigz -6 (10 threads)",    f"{TAR} | pigz -6 > {W}/o.gz", "o.gz"),
    comp("pigz -6 -p1",             f"{TAR} | pigz -6 -p1 > {W}/o.gz", "o.gz"),
    comp("libdeflate-gzip -6",      f"{TAR} | libdeflate-gzip -6 -c > {W}/o.gz", "o.gz"),
    comp("zstd -3",                 f"{TAR} | zstd -3 -q -c > {W}/o.zst", "o.zst"),
    comp("zstd -3 -T0",             f"{TAR} | zstd -3 -T0 -q -c > {W}/o.zst", "o.zst"),
    comp("lz4 -1",                  f"{TAR} | lz4 -1 -q -c > {W}/o.lz4", "o.lz4"),
    comp("brotli -5",               f"{TAR} | brotli -5 -c > {W}/o.br", "o.br"),
]
G["levels"] = [
    comp(f"bend {n} -{l}", bend(p, str(l)), "o.tgz") for n, p in BENDS for l in (1, 9)
] + [
    comp(f"gzip -{l}", f"{TAR} | gzip -{l} > {W}/o.gz", "o.gz") for l in (1, 9)
] + [
    comp(f"pigz -{l} (10 threads)", f"{TAR} | pigz -{l} > {W}/o.gz", "o.gz") for l in (1, 9)
] + [
    comp(f"libdeflate-gzip -{l}", f"{TAR} | libdeflate-gzip -{l} -c > {W}/o.gz", "o.gz") for l in (1, 9)
]
G["strong"] = [
    comp("bzip2 -9",          f"{TAR} | bzip2 -9 > {W}/o.bz2", "o.bz2"),
    comp("xz -6 -T0",         f"{TAR} | xz -6 -T0 -c > {W}/o.xz", "o.xz"),
    comp("zstd -19 -T0",      f"{TAR} | zstd -19 -T0 -q -c > {W}/o.zst", "o.zst"),
]
X = f"{W}/x"
def ext(name, cmd):
    return dict(name=name, cmd=f"rm -rf {X} && mkdir {X} && cd {X} && {cmd}", out=None, cwd=W, check=X)
G["extract"] = [
    ext(f"bend {n} -xzf", f"{os.path.abspath(p)} -xzf {W}/ref.tgz") for n, p in BENDS
] + [
    ext("C twin -xzf",           f"{TWIN} -xzf {W}/ref.tgz"),
    ext("bsdtar -xzf",           f"bsdtar -xzf {W}/ref.tgz"),
    ext("gzip -dc | bsdtar -x",  f"gzip -dc {W}/ref.tgz | bsdtar -xf -"),
    ext("pigz -dc | bsdtar -x",  f"pigz -dc {W}/ref.tgz | bsdtar -xf -"),
    ext("libdeflate-gzip -dc | bsdtar -x", f"libdeflate-gzip -dc {W}/ref.tgz | bsdtar -xf -"),
    ext("zstd -dc | bsdtar -x",  f"zstd -dc -q {W}/ref.zst | bsdtar -xf -"),
    ext("xz -dc -T0 | bsdtar -x", f"xz -dc -T0 {W}/ref.xz | bsdtar -xf -"),
] + [
    ext(f"bend {n} -tzf (list)", f"{os.path.abspath(p)} -tzf {W}/ref.tgz > /dev/null") for n, p in BENDS
] + [
    ext("bsdtar -tzf (list)",    f"bsdtar -tzf {W}/ref.tgz > /dev/null"),
]

def run_once(c):
    t0 = time.perf_counter()
    p = subprocess.Popen(["/bin/sh", "-c", c["cmd"]], cwd=c["cwd"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    _, status, ru = os.wait4(p.pid, 0)
    wall = time.perf_counter() - t0
    err = p.stderr.read().decode(errors="replace")
    rc = os.waitstatus_to_exitcode(status)
    if rc != 0:
        raise SystemExit(f"FAIL {c['name']}: rc={rc}\n{err}")
    return wall, ru.ru_utime + ru.ru_stime, ru.ru_maxrss  # maxrss in bytes on macOS

def verify(c):
    if c.get("check"):
        d = c["check"]
        if c["name"].endswith("(list)"):
            return "list"
        for f in os.listdir(corpus):
            if subprocess.run(["cmp", "-s", os.path.join(corpus, f), os.path.join(d, f)]).returncode:
                raise SystemExit(f"MISMATCH {c['name']} {f}")
        return "roundtrip ok"
    o = os.path.join(W, c["out"])
    dec = {"o.tgz": "gzip -dc", "o.gz": "gzip -dc", "o.zst": "zstd -dc -q", "o.lz4": "lz4 -dc -q",
           "o.br": "brotli -dc", "o.bz2": "bzip2 -dc", "o.xz": "xz -dc"}[c["out"]]
    tarred = c["out"] == "o.tgz"
    # decode with the reference tool and compare to the reference tar stream (or the members)
    if tarred:
        d = f"{W}/v"; shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
        subprocess.run(f"{dec} {o} | bsdtar -xf -", shell=True, cwd=d, check=True)
        for f in os.listdir(corpus):
            if subprocess.run(["cmp", "-s", os.path.join(corpus, f), os.path.join(d, f)]).returncode:
                raise SystemExit(f"MISMATCH {c['name']} {f}")
    else:
        r = subprocess.run(f"{dec} {o} | cmp -s - {W}/ref.tar", shell=True)
        if r.returncode:
            raise SystemExit(f"MISMATCH {c['name']}")
    return "verified"

res = []
for c in G[group]:
    runs = [run_once(c) for _ in range(reps)]
    size = os.path.getsize(os.path.join(W, c["out"])) if c["out"] else None
    v = verify(c)
    walls = [r[0] for r in runs]
    r = dict(name=c["name"], cmd=c["cmd"], wall_min=min(walls), wall_med=statistics.median(walls),
             cpu_med=statistics.median(r[1] for r in runs), rss_max=max(r[2] for r in runs),
             size=size, raw=raw, ratio=(raw / size if size else None), check=v,
             load=os.getloadavg()[0])
    res.append(r)
    print(f"{r['name']:34} wall {r['wall_min']:7.2f}s (med {r['wall_med']:6.2f})  cpu {r['cpu_med']:7.2f}s  "
          f"rss {r['rss_max']/2**20:7.1f}M  " + (f"size {size:>10}  ratio {raw/size:5.3f}" if size else "") +
          f"  {v}  load {r['load']:.1f}", flush=True)
json.dump(res, open(out_json, "w"), indent=1)
