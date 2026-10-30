# MNIST CNN Accelerator on the DE10-Lite (MAX10)

A quantized convolutional neural network that classifies 28×28 MNIST digits **entirely in FPGA hardware** on a Terasic DE10-Lite (Intel MAX10 `10M50DAF484C7G`). All arithmetic is integer (int8 weights/activations, int32 accumulators), and the RTL is **bit-exact** with a Python integer reference model at every layer.

Select one of 30 pre-loaded test images on the switches, press a button, and the predicted digit appears on the seven-segment display.

| | |
|---|---|
| Board / device | DE10-Lite, MAX10 `10M50DAF484C7G` |
| Toolchain | Quartus Prime Lite 25.1 · SystemVerilog-2005 synthesizable subset |
| Training | Python (Google Colab) |
| Verification | Self-checking golden-vector testbenches (Questa – Intel FPGA Starter Edition) |
| Status | Bit-exact on 30/30 images, timing closed at 50 MHz |

---

## Network

```
28×28×1 ─► Conv 3×3×8 + ReLU ─► MaxPool 2×2 ─► Conv 3×3×16 + ReLU ─► MaxPool 2×2
        ─► Flatten (400) ─► Dense 400→64 + ReLU ─► Dense 64→10 ─► Argmax ─► HEX0
```

| Layer  | In → Out     | Params | Requant shift `n` | ReLU |
|--------|--------------|-------:|:-----------------:|:----:|
| conv1  | 28×28×1 → 26×26×8   | 80     | 25 | ✓ |
| pool1  | 26×26×8 → 13×13×8   | 0      | –  | – |
| conv2  | 13×13×8 → 11×11×16  | 1,168  | 24 | ✓ |
| pool2  | 11×11×16 → 5×5×16   | 0      | –  | – |
| dense1 | 400 → 64            | 25,664 | 24 | ✓ |
| dense2 | 64 → 10 (logits)    | 650    | 23 | – |

≈27 k int8 weights. Pooling twice before the dense layers keeps the flatten vector at 400, which keeps the dominant dense1 weight count small.

---

## Quantization (Python side)

Symmetric uniform affine int8 quantization (Jacob et al., 2018 — the TFLite integer-only scheme):

- **Weights:** per-output-channel symmetric, `s_w[c] = max|W[c]| / 127`, int8 in [−127, 127].
- **Activations:** per-tensor, scales from a calibration subset of *training* images.
- **Input normalization folded offline:** training used `pixel/255`; the `1/255` is absorbed into conv1's scale, so the board consumes raw uint8 pixels.
- **Bias:** int32, `round(b / (s_in · s_w[c]))`.
- **Requantization:** per-channel integer multiplier `M0[c]` (uint16) with a per-layer shift `n`:

  ```
  out = clamp( (acc · M0[c] + (1 << (n−1))) >>> n , lo, 127 )     lo = 0 (ReLU) or −128 (dense2)
  ```
  Arithmetic shift, round-to-nearest, ≥48-bit intermediate, clamp last.

Per-channel PTQ was sufficient for MNIST; QAT was not needed. The Python **integer** model (not the training framework) is the executable specification the RTL is verified against.

---

## Hardware architecture

Serial, time-multiplexed datapath: one MAC per layer engine, sequenced by per-layer FSMs; one layer active at a time; two ping-pong activation buffers in M9K.

```
de10lite_top        reset/input synchronisers, button debounce, HEX/LED mapping
└─ cnn_top          image ROM, ping-pong buffers, layer sequencing, argmax, 7-seg
   ├─ sync_rom      30-image ROM (23,520 × 8)
   ├─ sync_ram ×2   activation buffers bufA / bufB (8192 × 8)
   ├─ conv_layer ×2     (+ weight/bias/M0 ROMs, pipelined requantize)
   ├─ maxpool_layer ×2
   └─ dense_layer ×2    (+ weight/bias/M0 ROMs, pipelined requantize)
```

Tensor layout everywhere is HWC-linear, `addr = (h·W + w)·C + c`, so Flatten is free.

---

## Results (as built)

| Metric | Value |
|---|---|
| Functional | Bit-exact vs golden model — 30/30 images, every layer and final label |
| Fmax (Slow 85 °C) | ≈ 69.6 MHz (50 MHz required) |
| Setup / hold slack @ 50 MHz | +5.64 ns / +0.26 ns, 0 unconstrained paths |
| Logic elements | ≈ 2.3 k / 49,760 (~5 %) |
| DSP (9-bit) elements | 20 / 288 |
| Latency | ≈ 0.47 M cycles ≈ 9 ms per inference @ 50 MHz (serial baseline) |
| Float test accuracy (10k MNIST test set) | 98.62 % |
| Quantized (int8) test accuracy | 98.66 % |
| On-hardware accuracy | = quantized accuracy (see below) |

**Why on-hardware accuracy equals quantized accuracy:** the RTL is proven bit-exact with the integer model, layer by layer, in simulation, and spot-checked on the board. A bit-exact datapath cannot classify any image differently, so its 10k-test-set accuracy *is* the quantized model's — the full set is not run through the board.

---

## Repository layout

Put files in these folders:

```
.
├── README.md
├── LICENSE
├── .gitignore
├── notebooks/
│   └── mnist_cnn_quant.ipynb         # Colab: train → quantize → integer golden model → export (.mif + golden)
├── python/
│   └── prep_sim.py                   # notebook output → sim/mem/*.hex + sim/golden/*.txt
├── rtl/
│   ├── cnn_core.sv                   # sync_rom, sync_ram, requantize
│   ├── conv_layer.sv
│   ├── maxpool_layer.sv
│   ├── dense_layer.sv
│   ├── cnn_top.sv
│   ├── de10lite_top.sv
│   ├── cnn.sdc                       # timing constraints (50 MHz clock + false paths)
│   └── de10lite_pins.qsf             # pin assignments (+ memory-init config note)
├── sim/
│   ├── tb/                           # testbenches: per-layer, full-system (cnn_top), board-wrapper
│   ├── mem/                          # exported *.hex: <layer>_w/_b/_m0.hex, images.hex
│   └── golden/                       # golden per-layer vectors imgNN_<layer>.txt + labels
└── quartus/
    ├── cnn_de10lite.qpf              # Quartus project
    └── cnn_de10lite.qsf              # project settings
```

> Adjust `.sv` file names to match yours — the module names above are the ones used in the design. If your modules all live in fewer files, keep them under `rtl/`.

**Keep `sim/mem/` and `sim/golden/` from one Python run.** Weights, image ROM and golden vectors must be regenerated together; regenerating only one desynchronises the set and every layer fails verification.

**The committed `sim/` set is frozen.** It is the exact set the hardware was verified and built with (requant shifts 25/24/24/23, accuracies above). Re-running the notebook will most likely *not* reproduce it bit-for-bit — TensorFlow training is not fully deterministic, especially on GPU — so a fresh run gives a new, self-consistent set that may come with different shifts (see [Reproducing](#reproducing)).

Suggested `.gitignore` (Quartus build output):

```
quartus/db/
quartus/incremental_db/
quartus/output_files/
quartus/qdb/
quartus/tmp-clearbox/
*.qws
*.bak
sim/work/
*.vcd
*.wlf
__pycache__/
.ipynb_checkpoints/
```

Commit the `.sof` only if you want a ready-to-program bitstream — put it in a GitHub Release rather than the tree.

---

## Reproducing

### 1. Train, quantize, export (Colab)
Skip this step to use the frozen, verified set already in `sim/`.

Open `notebooks/mnist_cnn_quant.ipynb` in Google Colab and run all cells. It trains the float model, builds the integer model, reports float and int8 test-set accuracy, and downloads `mnist_fpga_python_phase.zip` containing:
- `weights/<layer>_w.mif`, `weights/<layer>_b.mif`, `images.mif`
- `quant_params.json` (per-layer shift `n` and per-channel `M0`)
- `golden/imgNN_layers.txt` (all layers of one image per file) and `golden/predicted_labels.txt`
- `REPORT.md` (float / int8 accuracy), demo PNGs

Convert that into the files the testbenches and `$readmemh` read:

```bash
mkdir run && cd run && unzip ../mnist_fpga_python_phase.zip
mkdir -p sim/mem sim/golden
python3 ../python/prep_sim.py        # writes sim/mem/*.hex and sim/golden/imgNN_<layer>.txt + labels.txt
cp -r sim/mem sim/golden ../sim/     # replace both together, never one alone
```

`prep_sim.py` prints the conv1 shift; check all four in `quant_params.json`. If any differ from the `SHIFT` parameters in `rtl/cnn_top.sv` (25/24/24/23), update `cnn_top.sv` to match, then re-run simulation before building.

### 2. Simulate
Run the testbenches in `sim/tb/` with Questa – Intel FPGA Starter Edition (free with Quartus Prime Lite). Run from the repository root: the testbenches open `sim/mem/` and `sim/golden/` by relative path.

| Testbench | Checks |
|---|---|
| `tb_conv1` | conv1 alone vs golden (image 0) |
| `tb_unit` | one layer vs golden; select with `+define+POOL1` / `CONV2` / `POOL2` / `DENSE1` / `DENSE2` |
| `tb_top` | full system: every layer of all 30 images + final labels |
| `tb_board` | board wrapper: reset/input sync, bouncy button debounce, HEX0 |

```bash
vlib work
vlog -sv rtl/*.sv sim/tb/tb_top.sv
vsim -c tb_top -do "run -all; quit"
```
For a unit test, e.g. conv2: `vlog -sv +define+CONV2 rtl/*.sv sim/tb/tb_unit.sv` then `vsim -c tb_unit -do "run -all; quit"`.

Expected: 0 per-layer mismatches, 30/30 labels correct (`RESULT: PASS`). The scoreboard reports the first diverging layer and index on failure.

### 3. Build in Quartus Prime Lite 25.1
1. Device `10M50DAF484C7G`, top-level `de10lite_top`. Add `rtl/*.sv` and `rtl/cnn.sdc`; import `rtl/de10lite_pins.qsf`.
2. **Enable memory initialisation (required on MAX10):** Assignments → Device → Device and Pin Options → Configuration → Configuration mode = **Single Uncompressed Image with Memory Initialization**. Without it, the initialised ROMs are built from logic instead of M9K, inflating logic and failing timing.
3. Point `$readmemh` at the hex files. Quartus resolves relative paths from the project directory, so with the project in `quartus/` either set the top-level parameter `MEMDIR="../sim/mem/"`, or copy `sim/mem/*.hex` into `quartus/` and use `MEMDIR=""`.
4. Compile and confirm positive setup slack at the Slow 85 °C corner in the Timing Analyzer.

### 4. Run on the board

| Control | Function |
|---|---|
| `SW[4:0]` | image index 0–29 (= digit × 3 + variation) |
| `KEY[1]` | run one inference |
| `KEY[0]` | reset |
| `HEX0` | predicted digit |
| `LEDR[0]` / `LEDR[1]` | busy / done |

Acceptance check: `SW=3` → `1`, `SW=27` → `9`.

---

## Possible extensions
- Output-channel-parallel or line-buffered streaming convolution (must stay bit-exact with the serial baseline).
- UART input path for arbitrary images.
- Sub-8-bit / mixed-precision quantization, where an accuracy-vs-resources trade-off reappears on MNIST.

---

## References
- B. Jacob et al., *Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference*, CVPR 2018.
- R. Krishnamoorthi, *Quantizing deep convolutional networks for efficient inference: A whitepaper*, arXiv:1806.08342, 2018.
- Reference student project: [m-kvlk/FPGA-8bit-Quantized-CNN-Accelerator](https://github.com/m-kvlk/FPGA-8bit-Quantized-CNN-Accelerator) — this design adds held-out test-set accuracy, an SDC with timing sign-off, per-layer bit-exact verification, rounding requantization, a two-stage conv network, and debounced/synchronised I/O.

## License
MIT — see [`LICENSE`](LICENSE).
