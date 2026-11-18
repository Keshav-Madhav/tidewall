import re, subprocess, sys, json
# prints {pid: [name, accumulatedGPUTime ns]} for every GPU client
out = subprocess.run(['ioreg','-c','AGXDeviceUserClient','-r','-d','1','-w','0'], capture_output=True, text=True).stdout
res = {}; cur = None
for line in out.splitlines():
    m = re.search(r'IOUserClientCreator" = "pid (\d+), (.*)"', line)
    if m: cur = m.group(1); res.setdefault(cur, [m.group(2), 0]); continue
    if cur and 'accumulatedGPUTime' in line:
        res[cur][1] += sum(int(x) for x in re.findall(r'accumulatedGPUTime"=(\d+)', line))
json.dump(res, sys.stdout)
