# poolamaminer Custom Package

`poolamaminer` wraps the standalone `gpu` binary so it can be used as a custom miner on Hive OS rigs.

## Supported Targets
- Hive OS 0.6+
- NVIDIA GPUs (CUDA)

## Installation
1. Upload `poolamaminer-0.1.0.tar.gz` to your rig (`/hive/miners/custom`).
2. Run `tar -zxf poolamaminer-0.1.0.tar.gz` in `/hive/miners/custom`.
3. In the Flight Sheet set `CUSTOM_MINER=poolamaminer`. You can reuse the public release archive via the Install URL if preferred:
   `https://github.com/Printscan/poolamaminer/releases/download/0.1.0/poolamaminer-0.1.0.tar.gz`

## Flight Sheet Fields
- **Wallet (CUSTOM_TEMPLATE):** Hive wallet address or login. Populates the `WALLET` environment variable.
- **Pass (CUSTOM_PASS):** Miner secret. Defaults to `%WORKER_NAME%`. You can embed overrides, e.g. `SECRET=mysecret RIG=myworker`.
- **Pool URL:** Optional; the miner connects directly using env variables and does not require `CUSTOM_URL`.
- **Extra Config (CUSTOM_USER_CONFIG):**
  - Remaining CLI flags passed to the `gpu` binary.
  - Optional overrides: `RIG=myworker`, `SECRET=othersecret`.
  - GPU tuning via `nvtool` (e.g. `nvtool --setclocks 2400 --setmem 7001`).

## Runtime Behaviour
- `h-config.sh` generates `config.env` with `RIG`, `SECRET`, `WALLET`, plus leftover user arguments.
- `h-run.sh` exports the env vars, applies any `nvtool` commands, and logs via `stdbuf` so output is streamed to `/var/log/miner/poolamaminer/poolamaminer.log`.
- `h-stats.sh` reads the miner log for lines like `GPU[1] 148090 0`, combines them with `/run/hive/gpu-stats.json`, and reports total/per‑GPU hashrate in kH/s along with temps/fans.

## Log & Stats
- Log file: `/var/log/miner/poolamaminer/poolamaminer.log`
- Stats command: `bash /hive/miners/custom/poolamaminer/h-stats.sh`

## Packaging
Rebuild the archive whenever scripts change:
```bash
tar -zcvf poolamaminer-<version>.tar.gz poolamaminer
```
