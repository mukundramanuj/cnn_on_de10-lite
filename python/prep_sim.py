import json, re, numpy as np, os

def mif_data(path):
    """Return list of ints (data column) from a Quartus .mif, in address order."""
    vals = {}
    for line in open(path):
        m = re.match(r'\s*(\d+)\s*:\s*([0-9a-fA-F]+)\s*;', line)
        if m: vals[int(m.group(1))] = int(m.group(2), 16)
    return [vals[a] for a in range(len(vals))]

P = json.load(open("quant_params.json"))["layers"]

# ---- ROM hex files for $readmemh (weights int8, bias int32, M0 uint16) ----
for name in ("conv1","conv2","dense1","dense2"):
    w = mif_data(f"weights/{name}_w.mif")          # already two's-complement bytes
    b = mif_data(f"weights/{name}_b.mif")          # 32-bit two's complement
    m0 = P[name]["M0_per_channel"]
    open(f"sim/mem/{name}_w.hex","w").write("\n".join(f"{v:02x}" for v in w)+"\n")
    open(f"sim/mem/{name}_b.hex","w").write("\n".join(f"{v:08x}" for v in b)+"\n")
    open(f"sim/mem/{name}_m0.hex","w").write("\n".join(f"{v:04x}" for v in m0)+"\n")

# ---- image ROM (all 30 images, uint8) ----
img = mif_data("images.mif")
open("sim/mem/images.hex","w").write("\n".join(f"{v:02x}" for v in img)+"\n")
IMAGES = np.array(img, dtype=np.int64).reshape(30,784)

# ---- split each golden file into per-layer decimal vectors ----
LAYERS = ["conv1","pool1","conv2","pool2","flatten","dense1","logits"]
labels = [int(x) for x in open("golden/predicted_labels.txt").read().split()]
for k in range(30):
    txt = open(f"golden/img{k:02d}_layers.txt").read().splitlines()
    cur=None; buf=[]; sect={}
    for ln in txt:
        if ln.startswith("#"):
            if cur is not None: sect[cur]=buf
            buf=[]
            mm=re.match(r'#\s*(\w+)', ln[1:]) if False else re.match(r'#\s*(\w+)', ln)
            cur = mm.group(1) if mm else None
            # skip the very first title line "# demo index..."
            if cur=="demo": cur=None
        else:
            if ln.strip(): buf.append(int(ln))
    if cur is not None: sect[cur]=buf
    # input to conv1 is the raw image
    open(f"sim/golden/img{k:02d}_input.txt","w").write("\n".join(map(str,IMAGES[k]))+"\n")
    for L in LAYERS:
        if L in sect:
            open(f"sim/golden/img{k:02d}_{L}.txt","w").write("\n".join(map(str,sect[L]))+"\n")
open("sim/golden/labels.txt","w").write("\n".join(map(str,labels))+"\n")

# quick integrity check
assert len(IMAGES.reshape(-1))==23520
print("prep OK: images", IMAGES.shape, "| labels", labels[:6], "...")
print("conv1 shift", P["conv1"]["shift"], "M0[0]", P["conv1"]["M0_per_channel"][0])
print("sample: img00 conv1 first 5 golden =",
      open("sim/golden/img00_conv1.txt").read().split()[:5])
