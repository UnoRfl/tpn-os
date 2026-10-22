# iMin simulator

Pretends to be the counter's iMin D4-504 (printer, cash drawer, rear screen, the TPN Counter app's link and the kitchen network printer) so the real TPN pages can be tested on any PC.

```bash
node tools/imin-sim/imin-sim.js --local
```

Needs Node.js 18+ and Chrome, Edge or Firefox; no npm install. The dashboard is at http://127.0.0.1:7070/. Every option: `--help`. The full guide is in [HARDWARE.md](../../HARDWARE.md), section 7.
