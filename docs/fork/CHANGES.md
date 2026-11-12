# Fork changes

This fork builds on upstream `round-0.8.41` (`ef8491a`) and merges upstream's contemporaneous `main` documentation. The numeric plug-in version remains 0.8.41. Identify a fork build by its repository commit and its build record, rather than treating it as the upstream final release.

## Added in this fork

### AU parameter consistency and guarded lifecycle

Steinberg's wrapper took its initial parameter snapshot before TI Revive activated its default project. On the tested TI POLAR, AU parameter 153 initially returned 0 while the processor's initial Cutoff value was 127 (normalized 1). This caused a test host using the AU value as a restoration value to close the filter.

The TI Revive AU subclass now refreshes the host cache after successful activation and after processor-only or legacy AU state restoration. Updating the cache does not enqueue new parameter writes. The current controller/processor preset format keeps the SDK's existing cache update.

Partial initialization and invalid preset types are rejected before dereferencing the wrapped controller/processor or passing malformed Core Foundation values to the SDK. These are defensive improvements related to [upstream #38](https://github.com/derpsn/access-virus-ti-revive/issues/38), **not a claim to have reproduced or fixed that reporter's crash**.

A synthetic SDK lifecycle fixture and read-only `vti_autest --expect-param` assertions cover this behavior. The actual built AU was also checked; measurement details are in [PERFORMANCE.md](PERFORMANCE.md).

### Precompiled automation encoding

A single-parameter MIDI transport can be compiled into a fixed, owning 26-byte record before audio processing starts. The real-time path then copies the template and fills bounded fields instead of searching the device definitions by strings on every send. Parameter range bounds are cached at initialization too.

The original encoder remains the fallback for unsupported or longer formats. The original queue budget, throttling, event ordering, 7-bit behavior and hardware send guards remain in use. No request is parallelized or sent faster to the Virus. [Benchmarks and byte-equivalence checks](PERFORMANCE.md) describe the benefit and its limits.

### Windows legacy-driver migration guard

The original `$Matches` bug in [#31](https://github.com/derpsn/access-virus-ti-revive/issues/31) was already fixed upstream. A newer report describes a legacy `vtimidi.sys` unload crash while a device is present, including surprise removal and Access's own repair.

This fork checks present PnP devices and typed service properties before making driver/certificate changes and again before each legacy package deletion. A connected legacy binding or an inconclusive query stops migration. It does not ask a SYSTEM custom action to wait on an interactive prompt. Package deletion no longer requests `/uninstall /force`, and it no longer removes a live Access device node.

This is a mitigation of a trigger in the installer, not a repair of the legacy kernel driver. Windows PowerShell 5 and PowerShell 7 mock tests are run in the fork CI; Windows hardware migration remains unverified.

### Explicit resource selection and portable tests

An explicit Access resource path, `VTI_ACCESS_DIR`, or `VTI_ACCESS_CC` now selects that location authoritatively. A failed explicit selection reports its reason instead of silently falling through to another installed copy. Automatic discovery remains available when no override is specified. Regression tests now isolate missing-resource cases from the user's existing installation.

Mac library-root and diagnostic-path expectations follow their platform definitions. UTF-8 filename tests account for filesystem-equivalent NFC/NFD names rather than assuming distinct directory entries. These test repairs do not change the user's library locations or rewrite filenames.

### Build and documentation

The top-level native project explicitly enables Objective-C++ on macOS and declares C++23 for the AU target. This fixes the missing `CMAKE_OBJCXX_COMPILE_OBJECT` rule encountered with the Unix Makefiles generator.

The fork explicitly records macOS27 support and local27.2 runtime validation in [MACOS.md](MACOS.md), including packaged-AU editor lifetime checks. No unneeded OS-specific runtime branch is added.

The fork has Japanese and English entry points, keeps the upstream README, separates its measurements from upstream results, and tracks every open upstream issue in [ISSUES.md](ISSUES.md). No Access resources or private test logs are redistributed.

## Inherited from upstream, not new fork features

- Native AU/VST3, USB audio, RAM/ROM browser, patch libraries, automation and project state.
- Universal Mac binaries and the Snow plug-in.
- The 0.8.41 experimental low-latency option and its Control Center switch.
- The 0.8.38 Windows `$Matches` correction, Linux Snow endpoint correction, browser number spacing, and 0.8.41 minimum-macOS package guard.

See [README.upstream.md](../../README.upstream.md) and the [issue ledger](ISSUES.md) for their history and outstanding reports.

## Developer ID signing and notarization

The fork adds an inside-out signing/notarization helper and a main-only manual CI workflow. It verifies the successful build, source ancestry and artifact digest before importing the Application/Installer identities into an ephemeral keychain. Apple accepted the real package with no issues; stapling, Gatekeeper, cleanup and local macOS27.2 verification passed. Local release builds can request this path with `TIREVIVE_NOTARIZE=1`. The fork skips upstream's ad-hoc tag-publishing job. See [NOTARIZATION.md](NOTARIZATION.md).
