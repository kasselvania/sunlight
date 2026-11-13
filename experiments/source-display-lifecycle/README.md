# Source display lifecycle regression

Run explicitly on a Mac with an available desktop:

```sh
python3 experiments/source-display-lifecycle/check_lifecycle.py
```

This creates the real two Retina bank displays through `SLSourceDisplay`, then
repeats their creation across fresh processes and a killed owner. It opens no
windows, captures no pixels, moves no app windows and runs no animation. The
full Sunlight app should be closed so its two slots are available.

Checks cover stable, distinct display UUIDs, refusal of duplicate owners in the
same and a different process, invalid-slot refusal, normal and process-death
release, unchanged physical display geometry/mode, a bounded ColorSync profile
set after warm-up, and ColorSync settling. A busy ColorSync observation stops
the remaining exercises. This is an opt-in desktop integration check, outside
ordinary `swift test`.

Results and the native log go to `build/sip-redesign/display-lifecycle/`.
This establishes lifecycle behavior on the tested Mac; it does not qualify
capture performance, input, or compatibility with another running display tool.
