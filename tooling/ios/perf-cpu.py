# Summarise the CPU samples of tooling/ios/sim-smoke.sh --perf: python3 -I tooling/ios/perf-cpu.py <perf-probe dir>
import glob, os, re, sys, statistics
# Parse `top -l N -s 1 -stats pid,cpu,command` output: one block per sample, the first dropped.
d = sys.argv[1]
for f in sorted(glob.glob(os.path.join(d, 'cpu-*.txt'))):
    scene = os.path.basename(f)[4:-4]
    blocks = open(f, errors='replace').read().split('Processes:')[2:]
    per = {}
    for b in blocks:
        tot = {}
        for line in b.splitlines():
            m = re.match(r'\s*(\d+)\s+([\d.]+)\s+(\S+)', line)
            if m:
                name = m.group(3)
                key = 'Runner' if name.startswith('Runner') else 'WebKit'
                tot[key] = tot.get(key, 0) + float(m.group(2))
        for k, v in tot.items():
            per.setdefault(k, []).append(v)
    out = ', '.join(f'{k} {statistics.mean(v):.1f}% (max {max(v):.0f}, n={len(v)})' for k, v in sorted(per.items()))
    print(f'{scene:24} {out or "(no samples)"}')
