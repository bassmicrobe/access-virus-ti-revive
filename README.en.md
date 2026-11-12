# TI Revive — bassmicrobe fork

[日本語](README.md) · [Upstream](https://github.com/derpsn/access-virus-ti-revive) · [Changes](docs/fork/CHANGES.md) · [Measurements](docs/fork/PERFORMANCE.md) · [Issue coverage](docs/fork/ISSUES.md)

An Apple Silicon-focused fork of TI Revive for Access Virus TI USB audio, AU/VST3 editing and automation. It builds on upstream's `round-0.8.41`; upstream's existing low-latency mode and fixes remain credited to upstream.

This development fork focuses on AU parameter/state consistency, precompiled real-time automation encoding, Windows installer safeguards and reproducible diagnostics. Performance claims are scoped to the measurements in [PERFORMANCE.md](docs/fork/PERFORMANCE.md): an encoder microbenchmark is not a whole-plug-in CPU or USB-latency measurement.

## Requirements and use

You need a physical Virus TI-family synth, your own Access Virus TI Software Suite installer and an AU/VST3 host. macOS builds require 14.4 or later, including macOS 27. **macOS 27.2 / Apple Silicon has been runtime-tested**; see the [macOS validation guide](docs/fork/MACOS.md) for the exact scope. The plug-in is **TI Revive Virus Control**, or **TI Revive Virus Control (Snow)**. Audio flows from the hardware over USB through the plug-in into the host. The synth's DSP still generates the sound.

No Access binaries, firmware, XML, skins or banks are redistributed here. Setup extracts the required data from the installer you own. Firmware/OS/flash updates are not supported. Plug-in activation changes the current edit buffers; save pending edits and use a disposable project for tests.

Install a published package only from the release page of the intended repository. [Upstream releases](https://github.com/derpsn/access-virus-ti-revive/releases) and [fork releases](https://github.com/bassmicrobe/access-virus-ti-revive/releases) are distinct; if this fork has no release, build from source. Follow the [upstream installation instructions](README.upstream.md#installation), allow the chosen host's macOS microphone permission for USB audio, and park conflicting old drivers reversibly. Keep only one installed copy per plug-in ID. A source build does not replace your installed stable version. The setup script can ask `Remove original Access plugins? [Y/n]`: choose `N` to keep them; that action deletes rather than parks those old plug-ins.

## Build on Apple Silicon

The CMake build below creates the plug-in, Control Center and tests, but not the USB broker or Access resources. For USB tests, first install the upstream stable package and complete its Access-file setup, then target the fork component explicitly. The source build leaves the installed broker/stable version in place.

```sh
git clone --recurse-submodules https://github.com/bassmicrobe/access-virus-ti-revive.git
cd access-virus-ti-revive
cmake -S native -B build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4
cmake --build build --parallel 4
ctest --test-dir build --output-on-failure
```

Outputs: `build/VST3/Release`, `build/AU`, `build/ccapp`. For a fresh Mac, build the complete universal package including the broker with Xcode selected:

```sh
bash scripts/mac-build-release.sh "$PWD" 0.8.41 "$PWD/package-build"
```

Building a package does not install it; use the generated package and its included Access-file setup instructions. For other platforms and package builds see [upstream build documentation](README.upstream.md#building). Buildability and hardware validation are reported separately.

## Windows legacy driver migration

[Issue #31](https://github.com/derpsn/access-virus-ti-revive/issues/31) reports crashes while the legacy Access MIDI driver is unloaded, including surprise removal. The installer safeguard refuses destructive migration while an affected device is present. Shut Windows down, power the Virus off and disconnect it while the computer is off, then boot and retry. Power-cycle the Virus before its first TI Revive session. This mitigates one trigger; it does not repair the legacy driver or guarantee crash-free migration on every system.

## Experimental lower latency

The inherited Control Center **Lower latency (experimental)** option applies on the next plug-in start and is off by default. A short dedicated-host POLAR/Mac test at44.1kHz/512frames measured a92.880ms default versus55.147ms onset median with that actual option. This is separate from the manual1536-frame lead test and is not long-term DAW validation. Restore the default if notes become late or audio becomes unreliable; see [conditions and limits](docs/fork/PERFORMANCE.md).

## Support, attribution and license

Use the [fork issue tracker](https://github.com/bassmicrobe/access-virus-ti-revive/issues) for fork-specific regressions and consult the [issue coverage ledger](docs/fork/ISSUES.md). Remove personal data and credentials from logs. Do not interpret a mitigation or a passing test on one model as resolution of an untested upstream report.

TI Revive was created by derpsn and contributors. [The original README](README.upstream.md), [MIT license](LICENSE), copyright notices and third-party notices are retained. Neither upstream nor this fork is affiliated with Access Music or Kemper. Their trademarks identify compatibility. The upstream GPL proposal is a discussion, not a relicensing decision for this fork. AI assistance and actual verification are disclosed in change records.

These fork changes were prepared with AI assistance. Actual builds, tests, hardware observations and untested cases are recorded in the verification documentation.
