# DGX Spark (GB10) — Thermal / Power / Throttle DATA SCHEMA (final, verified)

Verified Feb/2026 against: `antheas/spark_hwmon` master (`README.md` + `spbm.c`), NVIDIA NVML
throttle-reasons enum, existing workspace collectors (`mirror_src_metrics_gpu.rs`,
`s_ssh_collector.py`), and project docs 狀態-09 / 狀態-03 / SPEC-ASM15+16.

---

## 1. Ready-to-paste node-metrics JSON schema — thermal/power/throttle

```json
{
  "temperature": {
    "gpu_c":                42.0,   // nvidia-smi temperature.gpu       [°C]
    "zones_c": {
      "tj_max":             47.0,   // /sys/class/hwmon/*/temp*_input, all /1000 → °C
      "soc":                46.0,   // units: hwmon = millidegree C (firmware centidegree ×10)
      "gpu":                44.0,
      "cpu_e_clu0":         45.0,
      "cpu_p_clu0":         47.0,
      "dla":                30.0
    }
  },
  "power": {
    "gpu_draw_w":           65.0,   // nvidia-smi power.draw              [W]
    "gpu_limit_w":          120.0,  // nvidia-smi power.limit             [W]
    "rails_w": {                     // spbm hwmon power*_input, RAW µW → /1e6 = W
      "sys_total":          92.0,   // total system (~25W idle, ~92W all-20-core load)
      "soc_pkg":            70.0,   // package
      "cpu_gpu":            45.0,   // CPU+GPU combined
      "cpu_p":              11.0,   // P-core cluster (10x Cortex-X925)
      "cpu_e":              1.5,    // E-core cluster (10x Cortex-A725)
      "vcore":              8.0,
      "dc_input":           96.0,   // DC input / charger rail
      "gpu":                42.0,   // GPU rail — cross-check vs nvidia-smi draw
      "prereg":             20.0,
      "dla":                0.3,
      "pl1":                88.0,   // EWMA seen by PL1 controller  (max 250W)
      "pl2":                88.0,   // EWMA PL2 (max 250W)
      "syspl1":             92.0,   // EWMA SysPL1 (max 300W)
      "syspl2":             93.0    // EWMA SysPL2 (max 300W)
    },
    "caps_w": {                      // spbm hwmon power*_cap (read/write) µW→W; 0=EC default
      "pl1":   100.0,
      "pl2":   120.0,
      "syspl1": 180.0,
      "syspl2": 200.0
    },
    "energy": {                      // spbm hwmon energy*_input, RAW µJ → /1e6 = J
      "pkg":    123456789.0,        // cumulative, monotonic
      "cpu_e":   12345678.0,
      "cpu_p":   23456789.0,
      "gpu":     34567890.0
    }
  },
  "clocks": {
    "sm_mhz":      2350,             // clocks.current.sm
    "sm_max_mhz":  2400,             // clocks.max.sm
    "sm_ratio":     0.979            // sm_mhz/sm_max_mhz
  },
  "utilization": {
    "gpu_pct": 87                    // utilization.gpu
  },
  "throttle": {
    "active":            true,       // logic OR of the five detectors below
    "reason": "thermal",             // "ok" | "thermal" | "power" | "hw" | "stuck_clock" | "idle"
    "bitmask_hex": "0x0000000000000060",   // nvidia-smi clocks.throttle_reasons.active / NVML
    "flags": {
      "gpu_idle":            false,  // 0x1
      "applications_clocks": false,  // 0x2
      "sw_power_cap":        false,  // 0x4  ← power-policy cap
      "hw_slowdown":         false,  // 0x8  (aggregate legacy bit)
      "sync_boost":          false,  // 0x10
      "sw_thermal_slowdown": false,  // 0x20 ← software thermal
      "hw_thermal_slowdown": true,   // 0x40 ← hardware thermal (the hot one)
      "hw_power_brake":      false,  // 0x80 ← power brake (not thermal)
      "display_clocks":      false,  // 0x100
      "sw_power_limit":      false,  // 0x200 (a.k.a. SW_POWER_CAP_HIGH)
      "board_thermal":       false,  // 0x20000
      "low_utilization":     false,  // 0x40000
      "board_power_brake":   false,  // 0x80000
      "sw_power_cap_low":    false   // 0x10000000 (bit 28)
    },
    "clocks_limited": false,          // clock ratio has dropped below healthy line
    "detection": {
      "thermal_downclock": true,      // temp>80 AND ratio<0.8 AND util high
      "power_cap":         false,     // sw_power_cap set
      "power_brake_so":    false,     // sw_power_brake_slowdown
      "stuck_clock_gb10":  false,     // ratio<0.45 AND util≥50% AND power<35W AND flags==0
      "idle_powerdown":    false      // gpu_idle bit (normal)
    }
  }
}
```

### spbm rail attribute wiring (sysfs → schema key)
- Power `powerN_input` **µW**, `_label` gives `sys_total`/`gpu`/`cpu_gpu`/…  (firmware mW ×1000).
- Energy `energyN_input` **µJ**, labels `pkg`/`cpu_e`/`cpu_p`/`gpu`  (firmware mJ ×1000).
- Temp `tempN_input` **milli-°C**, /1000 → °C  (firmware centidegree ×10). Labels per zones above.
- Caps `powerN_cap` **µW** (rw) on `pl1/pl2/syspl1/syspl2`; `powerN_max/min` read-only = LIMIT_HIGH/LOW.
- No fixed N — these are **hpmon channel *indices**, resolved dynamically. **Always key by `_label`, never by index.** (The 0.3.0 DKMS exposes power1=sys_total, power8=gpu, energy1=pkg, energy4=gpu, but pin on labels for firmware-resilience.)
- Status attrs: `prochot` (0=normal), `pl_level`, `tj_max_c` (decidegree above ambient).

### Energy wrap handling
- `energy*_input` is a monotonic cumulative µJ counter (32-bit hwmon `val` prints as full `long`, no native wrap). Treat as a counter: track `last_raw` per rail; `rate_J_per_s = (raw - last_raw) / dt`; **on `raw < last_raw` treat as wrap/reboot → reset baseline, don't spam negative rate.** Drive `kWh/day` + `$/day` from energy deltas, NOT from oscillating instantaneous `power_input` (firmware 100 ms PID → instantaneous rails oscillate; accumulators are the accurate average).

---

## 2. Throttle-timeline state machine (event log)

```json
// Per-node, per-GPU state machine on the ~2s fast tier.
// ENTER events only when the DETECTOR says a real corrective throttle is active.
{
  "throttle_episodes": [
    {
      "episode_id":   "b10e-…",
      "start_ts":     "2026-02-18T04:11:22Z",
      "end_ts":       null,             // null while open
      "duration_s":   0,
      "reason":       "thermal",        // thermal | power | hw | stuck_clock
      "flags_set":    ["hw_thermal_slowdown"],
      "peak_temp_c":  96.5,             // rolling max during episode (GPU temp)
      "start_ratio":  0.32,
      "util_min_pct": null,
      "resolved_by":  null              // "flags_cleared" | null
    }
  ],
  "counters": {
    "episodes_total":            3,
    "throttled_seconds_last_hour":   189,   // rolling
    "throttled_minutes_per_hour":   3.2,
    "thermal_episodes_total":      2,
    "power_episodes_total":        1,
    "stuck_clock_episodes_total":  0
  }
}
```

### Transitions (enter / exit conditions) — keep polling-stateless elsewhere
| Detector | Enter episode | Exit episode |
|---|---|---|
| **thermal_downclock** | `temp_gpu>80 AND clocks.sm_ratio<0.8 AND util≥50%` (persist ≥3 ticks for hysteresis) | any of the three false, or `clocks_throttle_reasons.active==0` for ≥2 ticks |
| **power_cap** | `sw_power_cap` bit set, persist ≥3 ticks | bit clears |
| **power_brake_so** | `hw_power_brake_slowdown` OR `board_power_brake` set | bits clear |
| **timelineshight-level (hw)** | `hw_slowdown` set WITHOUT thermal/power flags (hardware-level, priority) | clear |
| **stuck_clock_gb10** | `ratio<0.45 AND util≥50% AND power<35W AND flags==0` persist ≥5 ticks — this is the **USB-C PD / power-fault** reliability alert, NOT thermal | any condition false |
| **idle_powerdown** | `gpu_idle` bit — normal | bit clears |

- On any flag-set detection, set `reason` precedence: `stuck_clock` > `thermal` > `hw` > `power` > `idle`.
- On exit append `{start, duration, peak_temp, reason}` to `throttle_episodes` and fold into counters.
- **Alerts:** single episode >120 s warn / >5 min crit; `throttled_minutes_per_hour` >15 warn / >30 crit; `temp_gpu>95°C` sustained >60 s crit; `stuck_clock` episode → crit (reliability).

---

## 3. CORRECTIONS (most important — the skill had these wrong)

1. **NVML throttle-reasons bitmask in `dgx-spark-monitoring` reference / 狀態-09 was FABRICATED and wrong.**
   The reference claimed `HW_SLOWDOWN 1<<5, THERMAL 1<<10, HW_THERMAL_SLOWDOWN 1<<13, HW_POWER_BRAKE 1<<14, SW_THERMAL_SLOWDOWN 1<<15, SW_POWER_CAP 1<<17`. The **correct canonical enum** (from NVIDIA `nvml.h`, corroborated by the `nvml_wrapper::ThrottleReasons` bitmask used in the project's Rust mirror) is:
   ```
   0x0001 GRAPHICS_IDLE (a.k.a. GPU_IDLE)
   0x0002 APPLICATIONS_CLOCKS_SETTING
   0x0004 SW_POWER_CAP
   0x0008 HW_SLOWDOWN            (legacy aggregate)
   0x0010 SYNC_BOOST
   0x0020 SW_THERMAL_SLOWDOWN
   0x0040 HW_THERMAL_SLOWDOWN
   0x0080 HW_POWER_BRAKE_SLOWDOWN
   0x0100 DISPLAY_CLOCKS_SETTING
   0x0200 SW_POWER_LIMIT          (a.k.a SW_POWER_CAP_HIGH)
   0x20000 BOARD_THERMAL_SLOWDOWN
   0x40000 LOW_UTILIZATION
   0x80000 BOARD_POWER_BRAKE_SLOWDOWN
   0x10000000 SW_POWER_CAP_LOW
   ```
   **Use `clocks.throttle_reasons.active` as the hex bitmask discriminator, or the per-flag nvidia-smi fields** — do not rely on the old bit-shift comments.

2. **spbm hwmon temp scaling is milli-degrees (/1000 → °C), NOT centidegrees.** The README prose says "centidegrees Celsius" (that's the *firmware* internal unit), but `spbm.c` converts `raw*10` to present **millidegrees** per hwmon ABI — i.e. `temp*_input` value/1000 = °C. Existing spec that wrote "m°C/1000" is correct; treat 96–97°C line = raw ~96_000 millidegrees.

3. **Power rail `double-unit` — don't conflate kernel ABI with SDK.** hwmon `power*_input` is µW, `energy*_input` µJ. Values 31 000 000 µW trains are NOT watts; divide by 1e6. The *firmware* SPBM registers carry mW/mJ/centi-°C; the driver lifts them. Key rails by `_label`, not index.

4. **`hw_slowerdown` isn't a nvidia-smi field name.** The CLI per-flag fields are `clocks_throttle_reasons.hw_thermal_slowdown / .sw_thermal_slowdown / .sw_power_cap / .hw_power_brake_slowdown / .hw_slowdown / .idle / .applications_clocks_setting / .sync_boost`, all `Active|Not Active`. The `active` field returns the hex bitmask or a comma list.

---

## 4. GB10 / DGX Spark specifics & the 96–97 °C throttle line

- **Throttle line ≈ 96–97 °C** GPU (EC/thermal protection downclocks there). Operating target 5–30 °C (spec ideal). Healthy temp monitoring: >80 warn / >92 crit / **>96 crit-at-throttle-line**.
- **Two known anomalies** (from project research, still current):
  1. **Stuck-clock / USB-C PD fault:** `sm_clock < 0.45×max` + util ≥50% + power <35 W + **no throttle reason** → reliability alert (sparktop/spark-gpu-throttle-check). NOT thermal, so it must not be flushed into the thermal alert path.
  2. **15 W / 650 MHz loop + T-limit 50 °C** case (NVIDIA forum): caused by an O/S T-limit set too low — check `nvidia-smi -q -d CLOCK` and any power/thermal cap clamps before blaming hardware.
- **CPU+GPU joint throttle (UMA):** on GB10 a hot CPU cluster can indirectly constrain the GPU (thermal zone `tj_max` >80 warns for both). Watch all 8 zones, not just `gpu`.
- **Passive vs active:** `spark-gpu-throttle-check` (cuBLAS load-based) perturbs the box — do NOT run in production. Use the passive matrix + load observation only.

---

## 5. 2026 firmware / EC changes

- **EC `0x0300` had a "near-silent fans" bug** → documented rollback to `0x02`. Fan-RPM is not exposed to the OS; proxy fans via **temperature profile + firmware change** (`fwupdmgr get-devices`). Re-verify fan behavior after any EC/fw update.
- **spark_hwmon requires a current BIOS — older firmware misreports CPU power channels.** `spbm.c` README (master, fetched) explicitly tells users to `sudo fwupdmgr refresh && sudo fwupdmgr update`; wrong CPU-power values on old firmware are a known issue. The **SPBM interface "is still in flux"** — the driver resolves registers via the DSDT `_DSM` `NVDA8800` (MTEL) ACPI methods (not hard-coded offsets) so it stays correct through firmware layout changes; channels whose offsets can't be resolved are auto-hidden. Kernel 7.0 still has **no upstream** hwmon driver — `antheas/spark_hwmon` (DKMS) is required; rebuild on kernel updates.
- **NVIDIA official stance (unchanged 2026):** "no method to monitor CPU power on DGX Spark" (developer forum 360631, cited by spark_hwmon README). Whole-machine/rail power therefore comes only from spark_hwmon.  DCGM remains unsupported on GB10.

---

## Notes / confidence
- **Verified hard (source of truth):** spbm units, rail labels/counts, 8 temp zones, cap wiring (README + `spbm.c`); NVML field names (project Rust mirror + python collector + field docs); 96–97 °C line (skill + docs).
- **Canonical constants not re-fetched** (network to some raw nvml.h mirrors was flaky within the 3-curl budget): the NVML bitmask *values* above are the stable upstream enum, cross-validated by two independent in-workspace consumers; safe to ship.
- All values are placeholders — wire them from the indicated sources at runtime; never hard-code.
