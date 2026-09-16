---
name: nuttx-vendor-bsp-bringup
description: "Bring up a new SoC or board on openvela/NuttX inside a vendor tree and adapt its peripherals end to end: sibling-chip difference tables, manifest linkfile and custom chip/board wiring, defconfig, linker script, pinmux, clocks, startup, early console, interrupt controller, tick, heap, minimal NSH, then ladders for QSPI NOR + MTD + LittleFS, SDMC + FATFS, LVDS framebuffer, GT911 touch, buttons, watchdog, RTC, PWM, audio with DMA, GMAC RMII ethernet and SDIO Wi-Fi. Also covers DMA/cache coherency on non-coherent cores, PHY link timing, vendor HAL migration, evidence discipline and regression commands. Use when porting a new chip or board, when the board prints nothing or hangs before nsh, when a device node never appears, when DMA completes but data is zero, or when a PHY link or Wi-Fi firmware handshake fails."
---

# Vendor BSP Bring-up (openvela / NuttX)

Bring up a new SoC/board inside a vendor tree and take it to a verified, demonstrated state. Work in stages; do not skip the console.

> This skill complements `nuttx-driver-development` (which covers writing drivers under `nuttx/drivers/` for an already-ported board). Use this one when the **platform itself** is new: startup, clocks, interrupts, board files, and vendor-tree wiring.

## Table of Contents

1. [Scope](#scope)
2. [Hard rules](#hard-rules)
3. [Stage workflow](#stage-workflow)
4. [The bring-up loop](#the-bring-up-loop)
5. [Peripheral bring-up ladder](#peripheral-bring-up-ladder)
6. [Symptom to reference dispatch](#symptom-to-reference-dispatch)
7. [References](#references)
8. [Scripts](#scripts)

---

## Scope

**Use for**: a new chip or board with no existing openvela/NuttX port; a vendor tree where chip/board code is added under `vendor/`; "board prints nothing", "hangs before NSH", "node never appears", "DMA writes zeros", "PHY link down", "Wi-Fi firmware never answers"; migrating an existing port to a sibling chip.

**Not for**: writing a single driver into `nuttx/drivers/` on a board that already boots (use `nuttx-driver-development`); pure application/UI work.

## Hard rules

These rules exist because each one was learned by losing time to its violation.

1. **Evidence before claims.** Track the evidence level of every capability: `build` < `pack` < `boot` < `device` < `data`. Only `data` (a real board completing a data-path check) justifies "implemented and verified". Never present a build log as a run result, and never present "device node exists" as "data is correct". Details: `references/stages_and_gates.md`.
2. **Never modify production repositories.** Put code in the team/vendor working directory and wire it in with the manifest `<linkfile>` mechanism, a custom chip/board config, or fork+PR. The upstream `nuttx/`, `apps/`, `packages/` trees stay untouched. Details: `references/board_port_wiring.md`.
3. **Console first, everything else second.** No peripheral work until there is a stable, bi-directional console. A board that "prints but does not take input" is not up.
4. **One variable per board cycle.** Change one thing, flash, observe, record "before → after". Multi-variable changes destroy diagnosis.
5. **Register through the OS frameworks.** Use the standard upper halves (`input`, `buttons`, `watchdog`, `rtc`, `audio`/`pcm`, `mmcsd`, `mtd`, `netdev`, `fb`). Do not invent private ioctl channels for capabilities the OS already models.
6. **One peripheral = driver + one command + one README.** The command must print PASS/FAIL and cover the data path; the README records goal, dependencies, steps, expected result, measured result. Skeletons: `assets/templates/app_cmd_main.c`, `assets/templates/app_README.md`. Details: `references/verification_and_delivery.md`.
7. **Reuse a sibling chip's port as a reference, never as truth.** Copy architecture; re-derive every address, clock, reset bit, IRQ number and pin from the target's documentation. Details: `references/vendor_reference_migration.md`.
8. **Record every failure.** For each problem write: symptom/log → localization → root cause → fix → how it was verified → the reusable rule. This log becomes the regression checklist and the debugging playbook.

## Stage workflow

Proceed in order. Each stage has an entry condition and a required evidence level; enforce it before advancing.

| Stage | Goal | Gate (required evidence) |
|-------|------|--------------------------|
| **S0** | Documentation and sibling-chip difference table | difference table + rewritable/reusable file lists |
| **S1** | Repository skeleton and build wiring | `build` — build succeeds |
| **S2** | SoC minimal closure: startup, IRQ, tick, heap, early console | `boot` — serial log appears, never dies before `nx_start` |
| **S3** | Minimal NSH | `device` — `NuttShell (NSH)`, `nsh>` prompt, `help` works |
| **S4** | Base board peripherals (storage + control) | `device` → `data` — nodes appear, then read/write/event checks pass |
| **S5** | Display and input | `data` — panel shows the expected image; input events reported |
| **S6** | Audio, network, upper-layer app | `data` — audio in/out, DHCP+ping+HTTP, demo app runs |

Per-stage checklists, failure modes and the "minimal NSH is really up" criterion (banner **and** prompt **and** `help` output) are in `references/stages_and_gates.md`.

Gate commands:

```bash
scripts/bsp_state.sh init S3                      # adopt an in-progress port
scripts/bsp_state.sh complete S3 device           # record honest evidence
scripts/bsp_state.sh log S3 "nsh> prompt, help OK"
scripts/bsp_state.sh gate S4                      # blocks if evidence is insufficient
scripts/validate_stage.sh <repo> S4               # artifact/README checks
```

Stage boundaries: do not start display, audio or UI before the earlier stage is stable — those problems mask real SoC problems. Re-run the previous stage's checks after each new peripheral (adding I2C must not break UART, timers or task switching).

## The bring-up loop

```
Observe (log / register / scope)
   -> form one hypothesis
   -> add the smallest instrumentation that distinguishes it
   -> change one variable
   -> flash and verify on the board
   -> record symptom -> root cause -> fix -> rule
   -> remove the instrumentation, re-verify
```

Discipline:
- Prefer a probe that proves a *chain*, not a point. Writing one character to the UART transmit register from the first assembly instruction simultaneously proves the jump address and the UART base.
- Read the failure address out of the exception handler and resolve it with `objdump`/`addr2line` — do not guess.
- When a symptom is "nothing at all", suspect *bases and clocks* (interrupt controller, timer, core peripherals) before suspecting the driver.
- Do not wrap scheduling/exception core functions with instrumentation; it changes the stack and return path and produces fake crashes. Remove all probes before declaring a stage done.

## Peripheral bring-up ladder

Never jump straight to the frame/data path. Climb one rung at a time; each rung has its own verification.

```
1. Power / clock / reset     -> regulator, clock gate, deassert reset, delay
2. Pinmux                    -> pin -> function number -> peripheral
3. Bus presence              -> bus controller registers respond; device ACKs
4. Identity                  -> read a vendor/device ID register (proves protocol + addressing)
5. Configuration             -> write and read back the device's init/config (with checksum where available)
6. Data path                 -> interrupt / DMA / FIFO for the real payload
7. OS registration           -> register through the standard upper half; node appears
8. App + README              -> one command with an observable PASS/FAIL criterion
```

Typical rung failures: wrong bus address or address-selection (identity fails), device needs a specific reset/power sequence before configuration (steps 3–5 pass only after it), data path fails because of cache/DMA coherency (see `references/dma_cache_irq.md`), or timing is too aggressive (read status too early, enable backlight before the display engine is stable).

Peripheral-specific ladders (storage, display, touch, keys, watchdog/RTC, PWM, audio, ethernet, Wi-Fi) with the real checkpoints and gotchas: `references/peripheral_ladders.md`.

## Symptom to reference dispatch

| Symptom | Load |
|---------|------|
| Board prints nothing; dies before `nx_start`; no early log | `references/boot_and_core.md` (startup, bases, early console) |
| Chip code exists but is not compiled; `arch//include` empty; config change has no effect | `references/board_port_wiring.md` |
| New chip, sibling chip already ported; which files to rewrite | `references/vendor_reference_migration.md` |
| Hangs inside a driver, trap loop, wrong IRQ number, tick wrong | `references/boot_and_core.md` (interrupt controller, tick) |
| Device node missing / mount fails / block device cannot be opened / DMA completes but data is zero | `references/peripheral_ladders.md`, `references/dma_cache_irq.md` |
| Display blank, backlight sequencing, touch identity or coordinates wrong | `references/peripheral_ladders.md` |
| Ethernet link down, DHCP fails; Wi-Fi firmware handshake never answers | `references/peripheral_ladders.md` |
| "It seems to work" — need to decide whether it is verified | `references/verification_and_delivery.md` |
| Stuck on a specific failure and need a checklist | `references/debug_playbook.md` |

## References

Load only what the task needs.

| Reference | When to load | Contents |
|-----------|--------------|----------|
| `references/stages_and_gates.md` | At the start, and before claiming any stage done | S0–S6 goals, entry/exit criteria, evidence levels, stage boundaries |
| `references/boot_and_core.md` | Startup, interrupts, tick, heap, early console work | Address-chain consistency, first-instruction probe, interrupt controller traps, tick, RAM layout, console pitfalls, exception localization |
| `references/board_port_wiring.md` | Creating/repairing the chip and board directories | Layering, manifest linkfile, custom chip/board config, defconfig, linker script, pinmux/clock, board init timing, builtin apps, packing |
| `references/vendor_reference_migration.md` | Porting from a sibling chip | What must be rewritten vs borrowed, difference-table method, shared-header handling |
| `references/peripheral_ladders.md` | Bringing up any peripheral | Storage, display, touch, keys, watchdog/RTC, PWM, audio, ethernet, Wi-Fi ladders and timing gotchas |
| `references/dma_cache_irq.md` | DMA or interrupt-driven data paths | Descriptor rings, cache maintenance on non-coherent cores, barrier/constraint mistakes, IRQ routing and work-queue use |
| `references/debug_playbook.md` | Any concrete failure | Symptom → hypotheses → check → resolution tables for boot, bus, storage, display, audio, network |
| `references/verification_and_delivery.md` | Designing tests and assembling deliverables | Observable criteria, evidence discipline, regression list, documentation layers, delivery checklist |

## Scripts and templates

Contract: exit 0 on success, exit 2 on failure with a message on stderr.

| Script | Purpose |
|--------|---------|
| `scripts/bsp_state.sh` | Stage state machine: `init`/`complete`/`gate`/`evidence`/`log`/`note`/`status`. Prevents advancing on insufficient evidence. |
| `scripts/validate_stage.sh` | Artifact gate for a stage: checks files, symbols, Kconfig options, registrations and per-app README coverage. |
| `scripts/bsp_scan.sh` | Inventory a port: chip/board/app layout, core files, Kconfig, registered devices and `/dev` nodes, README coverage, packaging artifacts. Run this first when taking over or reusing a tree. |

```bash
scripts/bsp_scan.sh <team_repo>                 # what exists today
scripts/validate_stage.sh <team_repo> S4        # gate before marking S4 done
scripts/bsp_state.sh status
```

Copy-ready skeletons in `assets/templates/`:

| Template | Use |
|----------|-----|
| `assets/templates/app_cmd_main.c` | NSH test command: argument bounds, standard device open, explicit PASS/FAIL criterion, cleanup on every exit path |
| `assets/templates/app_README.md` | Per-peripheral README: dependencies, steps, expected result, pass criteria table, measured result, known limits |
| `assets/templates/board_bringup.c` | Board bring-up: pinmux → bus → device → framework ordering, logged registration results, deferred work for slow operations, early/late hooks |
