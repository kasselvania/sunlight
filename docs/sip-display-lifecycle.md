# SIP-enabled display lifecycle

## Defect and recovery

On 2026-11-13, the local desktop became choppy and its menu bar unusable after
extended Sunlight development. `SLSourceDisplay` assigned a random serial on
every creation. The older renderer experiment had a separate implementation
with the same defect. These launches accumulated 140 Sunlight-generated display
profiles, along with ColorSync device registrations.

The ColorSync processes repeatedly enumerated and rebuilt display profiles,
including profiles for banks 144 and 145 after those displays were offline.
Stopping Sunlight and BetterDisplay, and restarting individual ColorSync
services, did not settle that loop. Backing up Sunlight's profile files and
`/Library/Caches/ColorSync/com.apple.colorsync.devices`, then restarting all
three ColorSync processes together, resolved it. The user confirmed normal
desktop motion and menu-bar operation. The recovery did not reboot, log out,
restart WindowServer, weaken SIP, or remove physical monitor profile files.
Backup: `/Library/Application Support/Sunlight Recovery/20261113-101810`.

Identity accumulation is a confirmed application defect. The precise trigger
of the update loop, and BetterDisplay's involvement, have not been isolated.
The evidence does not establish a RAM leak. A separate restoration failure for
a replaced Accessibility system dialog also left an orphan host; that incident
was recovered, but its general window-restoration policy remains separate work.

## Ownership and identity

`Sources/SourceDisplay/SLSourceDisplay.m` owns the two-slot identity pool.
`Sources/Canvas/SourceBankHost.swift` creates the pair using explicit slot
numbers. The older `experiments/virtual-display-canvas` viewer uses slot 0
through that same implementation; its duplicate private declarations and
random-serial creation path have been removed.

| Slot | Vendor | Product | Serial | Display name |
| --- | --- | --- | --- | --- |
| 0 | `0x4b56` | `0x5342` | `0x53420001` | Sunlight Window Bank 1 |
| 1 | `0x4b56` | `0x5343` | `0x53420002` | Sunlight Window Bank 2 |

These values remain fixed across launches. Name, product and serial distinguish
simultaneous banks. Invalid slots are refused. An exclusive `flock` on a stable
per-slot file prevents another instance of either executable from claiming the
same identity. Lock files remain in Application Support; unlinking them would
allow competing owners to lock different inodes. The kernel releases the lock
on process death. Creation also refuses an identical display still present in
WindowServer's online list while its old owner is being retired.

Releasing the wrapper releases its virtual display and slot lock. The host
reports completed teardown only when its displays are absent from the online
list, including inactive displays. Failed online enumeration cannot claim
completed removal. No new identity is allocated to bypass a busy slot.

Two cached profiles are expected: macOS can remember these two monitors after
they disconnect. Reusing that bounded set avoids per-launch growth. The app
does not delete system profiles, reset ColorSync caches, disable services, or
require root at runtime. Historical random-identity artifacts require a
separate one-time cleanup; the live host performs no broad cleanup.

## Verification

The opt-in [lifecycle fixture](../experiments/source-display-lifecycle/README.md)
compiles the actual Objective-C owner with warnings as errors. It creates both
3072 × 2048 logical, 2×, 100 Hz banks without windows, capture, animation or AX
placement. Native checks passed for normal exit, a killed owner, and subsequent
normal exit in fresh processes. Duplicate construction in the same and another
process was refused. An out-of-range slot was refused.

The bank UUIDs remained `029B9A14-3DA1-4A7A-89E6-35C31ED2986B` and
`76F83FFC-3577-4F38-A154-A466E3B1A97F`. The profile file/registration set did not
grow after its two-profile warm-up. Only the physical display remained online
after each case, with its original 3430 × 1447 logical geometry, 6860 × 2894
backing resolution and 100 Hz refresh. ColorSync settled after each creation.

The first fixture attempt timed out on a five-second ColorSync read after owner
death, while displays had been removed and services subsequently observed idle.
The final fixture avoids unnecessary AppKit initialization for read-only
queries and separately allows fifteen seconds for that IPC read. Its three
post-release queries completed in 1.13, 2.91 and 3.50 seconds. This is not an
input-latency or physical presentation measurement.

Local evidence: `build/sip-redesign/display-lifecycle/result.json`, `native.log`,
`check.log`, `first-check-query-timeout.json`, and `swift-tests.log`. The Debug
build and six focused geometry, process identity, legacy journal and IOSurface
lease tests passed. The older renderer also compiled with warnings as errors.

The full canvas and animation stayed closed. This check does not establish
whole-product compatibility, BetterDisplay coexistence, frame pacing or
sustained capture throughput. Unfinished input edits are excluded from the
signed build for this fix.
