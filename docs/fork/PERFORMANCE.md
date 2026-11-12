# Performance and validation

This document separates **measurements on this fork**, **prior stable-version hardware checks**, **upstream results**, and **unmeasured expectations**. It is not a claim that one short recording validates every host, model or session length.

## Test setup

- Date: 2026-11-12.
- Apple Silicon MacBook Pro, M1 Max; macOS 27.2.
- Access Virus **TI POLAR**, OS 5.1.7.00, USB device 133e:0815.
- Apple Clang 21.0.0; native arm64 Release build, deployment target 14.4.
- Dedicated explicit-bundle AU/VST3 hosts. A previous stable-version AU load in Live 11.3.35 succeeded, but the DAW/scanner was then stopped because unrelated products requested authorization. No all-plug-in scan is required for these tests.
- Four RAM banks / 512 patches were backed up and parsed. Read-only fingerprint comparisons after both the stable-version and fork hardware tests reported all 512 unchanged. Private banks, snapshots and logs are not committed.

## Encoder microbenchmark

Synthetic fixture: 384 parameters, 128 controller mappings per template, 1,000,000 calls per run, five runs, arm64 `clang -O3`. Both encoders receive the same inputs and produce an accumulated result.

| Path | Median per encode | Five-run range |
|---|---:|---:|
| Legacy string/model lookup | 363.626 ns | 361.428–366.608 ns |
| Precompiled fixed record | 9.688 ns | 9.597–9.874 ns |

The measured helper speedup is **37.535×**. This is **not** the whole plug-in CPU speedup or a USB latency reduction. At 96 encodes it corresponds to about 34 microseconds in this fixture; total impact depends on event density and host scheduling. Normal light use can have a much smaller overall difference.

The compiled record occupies 26 bytes and does not keep a pointer into the model. The compiled encode path allocates no memory and takes no lock. Unsupported transports retain the previous path and byte semantics.

### Real-file byte-equivalence check

The owner's Access resources were read locally through the existing resource API. No XML, controller names, proprietary bytes or files are redistributed.

| Device model | Automation entries | Compiled / fallback | Comparisons | Mismatches |
|---|---:|---:|---:|---:|
| TI | 2,671 | 2,623 / 48 | 335,744 | 0 |
| Snow | 668 | 656 / 12 | 83,968 | 0 |
| Total | 3,339 | 3,279 / 60 | **419,712** | **0** |

These compare the compiled encoding against the existing encoder over values 0–127 for each mapped part. They test transport equivalence, not Snow hardware behavior. Synthetic boundary/lifetime/unsupported-format tests also pass under AddressSanitizer and UndefinedBehaviorSanitizer.

### Reproduce

```sh
cmake -S native -B build -DCMAKE_BUILD_TYPE=Release -DVTI_BUILD_BENCHMARKS=ON
cmake --build build --parallel 4 --target encodingbench vtitests
build/bin/Release/encodingbench
build/bin/Release/encodingbench --verify-access
```

The second command reads the user's installed Access data and makes no USB connection. It prints counts and mismatches only. Output paths differ with platform/generator.

## AU cache regression

The prior stable AU returned parameter 153 as 0 while its processor's initial Cutoff was 127 / normalized 1. This discrepancy was found in a dedicated test; it must not be confused with a claim that the upstream issue #38 crash was reproduced.

The fork's synthetic lifecycle fixture exercises activation, current/legacy/processor-only presets, partial initialization and malformed Core Foundation values. Before the fix, 30 checks failed; after the fix, all 36 pass. The built AU also passed a read-only `--expect-param 153 1` assertion after initialization.

```sh
ctest --test-dir build --output-on-failure
build/bin/Release/vti_autest 'build/AU/TI Revive Virus Control.component' \
  --expect-param 153 1 --no-notes --seconds 2
```

The assertion reads the AU value without setting a parameter. Activating the plug-in still performs its normal edit-buffer setup on the connected Virus. Save pending edits first. A test fixture does not validate every DAW automation/recall workflow.

## USB audio and latency

With stable upstream 0.8.40, the dedicated AU host captured six seconds of stereo USB audio at 44.1 kHz after a 12-second warmup and a short C4 note. Peak was 0.07522583, RMS 0.00841785, with no clipped samples. This establishes that USB audio works on the POLAR/Mac setup; it is not a long-term stability or speaker-listening test of this fork.

The 0.8.41 low-latency mode is **upstream work** and remains experimental. Its reduced scheduling margin can increase late notes if the host stalls. Do not treat Linux TI2 measurements as measurements on this POLAR or make a zero-latency claim. The fork VST3 host was run twice for 25 seconds at 44.1 kHz / 512 samples, with C4 on the first half of each second. One run used the default lead 3072, the other used the existing manual measurement override `VTI_NATIVE_A=1536` (a separate setting from the Options switch). No global preference was changed. Only the final steady window, 15–25 seconds, was analyzed.

| POLAR / macOS setting | Detected notes in steady window | Median WAV onset after note grid | Range |
|---|---:|---:|---:|
| Default lead 3072 | 10 / 10 | 92.880 ms | 92.880–93.673 ms |
| Lower lead 1536 | 10 / 10 | 58.050 ms | 58.050–59.410 ms |

A third run enabled the actual **Lower latency** option, explicitly omitted `VTI_NATIVE_A`, and restored the preference afterward. The plug-in logged a 1408-frame lead. In the same final steady window it returned 10/10 notes, median **55.147 ms**, range **55.147–55.782 ms**. The numeric record is [polar-low-latency-option.json](measurements/polar-low-latency-option.json).

The manual 1536-frame comparison differs from the default by **34.830 ms**; the actual Options comparison differs by **37.732 ms**. Detection uses the existing `scripts/timing_analysis.py` onset function (5 ms RMS envelope and 20% threshold); it includes the patch's attack and detection threshold. This is not a direct measurement of MIDI timestamp jitter, physical-key latency or speaker round-trip latency. These short runs do not establish the reduced margin's long-term stability in a DAW.

The manual lead override and the Options algorithm are upstream timing work, tested separately here on the POLAR/Mac; neither is a new fork algorithm. The safe default remains unchanged. Raw audio and private logs stay outside the repository. Numeric records without personal data are in [measurements](measurements/).

## Verification status

Windows PowerShell 5.1 and PowerShell 7 each passed all 26 fake-device assertions in [fork CI](https://github.com/bassmicrobe/access-virus-ti-revive/actions/runs/43156387356). The tests parse the installer scripts and mock every PnP/native call; they do not exercise a real legacy driver unload.

The rebuilt AU passed the read-only initial Cutoff assertion (parameter 153 = 1). A subsequent isolated AU test changed that parameter by 1/127, saved the local state, restored 1 and received USB audio; render, local edit, local restore and cleanup all passed. This verifies the AU API/processor workflow; hardware parameter echo was not independently measured. Full project-state recall was deliberately not exercised.

A copied test component with its embedded VST3 removed returned `kAudioUnitErr_FailedInitialization` (-10875) and disposed cleanly. This is a tested failure path, not reproduction of the incomplete crash report in upstream #38.

Local native CMake/CTest passed all four suites: 655 native tests (one platform-specific skip, zero failed checks), 36 synthetic AU lifecycle checks, the plug-in factory/class check, and 125 Python tooling tests. Both normal and Snow AU targets, VST3, Control Center, CLI, explicit hosts and the encoding benchmark built successfully on arm64.

The final read-only bank fingerprint check after fork tests reported all four banks / 512 programs up to date with the backed-up cache. Stored patches were unchanged.

The complete [package build at `f27645c`](https://github.com/bassmicrobe/access-virus-ti-revive/actions/runs/43156396159) passed:

| Platform | Build/test result | Runtime scope |
|---|---|---|
| macOS | Universal AU/VST3, Control Center, CLI, broker and `.pkg`/ZIP generated; arm64 and x86_64 slices verified | Local arm64 / POLAR tests above; Intel runtime untested |
| Windows x64 | MSVC native targets, CTest (including installer/Python tests), broker, MSI and setup EXE passed | CI/mocks only; no legacy-driver hardware unload |
| Linux x64 | Native build with project warnings treated as errors, CTest and distribution package passed | CI only; no Linux/Snow hardware test here |

A Windows test fixture initially expanded an explicit CRLF into CRCRLF in text mode. It now writes exact binary bytes and verifies those bytes; the production log reader was unchanged. The subsequent complete build above passed. The release job was skipped for this development branch: these are build artifacts, not a published upstream release. The installed local stable version remains 0.8.40.

Windows/Intel/Linux/Snow hardware, long-running DAW sessions, project save/reopen and subjective audio quality remain separate verification targets.
