# Oracle run

| fixture | kind | class | worst | mean | tol | verdict |
|---|---|---|---|---|---|---|
| hsv-identity | Hue/Saturation | exact | 0 | 0.000 | 1 | consistent |
| hsv-master | Hue/Saturation | exact | 12 | 0.278 | 1 | DIVERGES |
| hsv-reds | Hue/Saturation | exact | 14 | 0.197 | 1 | DIVERGES |
| levels-identity | Levels | exact | 0 | 0.000 | 1 | consistent |
| levels-work | Levels | exact | 0 | 0.000 | 1 | consistent |
| levels-clip | Levels | exact | 0 | 0.000 | 1 | consistent |
| curves-identity | Curves | exact | 0 | 0.000 | 1 | consistent |
| curves-s | Curves | exact | 0 | 0.000 | 1 | consistent |
| exposure-identity | Exposure | exact | 0 | 0.000 | 1 | consistent |
| exposure-up | Exposure | exact | 0 | 0.000 | 1 | consistent |
| gradientmap-default | Gradient Map | exact | 0 | 0.000 | 1 | consistent |
| gradientmap-duotone | Gradient Map | exact | 0 | 0.000 | 1 | consistent |
| gradientmap-reversed-bw | Gradient Map | exact | 0 | 0.000 | 1 | consistent |
| gradientmap-warm-end | Gradient Map | exact | 0 | 0.000 | 1 | consistent |
| grain-default | Grain | exact | 0 | 0.000 | 1 | consistent |
| grain-coarse | Grain | exact | 0 | 0.000 | 1 | consistent |
| addnoise-uniform | Add Noise | exact | 0 | 0.000 | 1 | consistent |
| addnoise-gaussian-mono | Add Noise | exact | 0 | 0.000 | 1 | consistent |
| gaussianblur-min | Gaussian Blur | kernel | 0 | 0.000 | 1 | consistent |
| gaussianblur-medium | Gaussian Blur | kernel | 4 | 0.177 | 6 | consistent |
| motionblur-min | Motion Blur | kernel | 0 | 0.000 | 1 | consistent |
| motionblur-30deg | Motion Blur | kernel | 73 | 1.975 | 32 | DIVERGES |
| invert-chart | Invert | exact | 0 | 0.000 | 1 | consistent |
| invert-alpha | Invert | alpha | 1 | 0.001 | 2 | consistent |
| blackwhite-default | Black & White | exact | 0 | 0.000 | 1 | consistent |
| blackwhite-tinted | Black & White | exact | 0 | 0.000 | 1 | consistent |
| colorbalance-identity | Color Balance | exact | 0 | 0.000 | 1 | consistent |
| colorbalance-warm | Color Balance | exact | 0 | 0.000 | 1 | consistent |
| colorbalance-noluminosity | Color Balance | exact | 0 | 0.000 | 1 | consistent |
| control-base | none | exact | 0 | 0.000 | 0 | consistent |
| control-identity-normal | Levels | exact | 0 | 0.000 | 0 | consistent |
| effect-coloroverlay | effects | exact | 1 | 0.018 | 1 | consistent |
| effect-stroke-outside | effects | exact | 0 | 0.000 | 1 | consistent |
| effect-stroke-inside | effects | exact | 0 | 0.000 | 1 | consistent |
| effect-shadow-hard | effects | exact | 0 | 0.000 | 1 | consistent |
| effect-shadow-ang180 | effects | exact | 0 | 0.000 | 1 | consistent |
| effect-shadow-blur | effects | kernel | 1 | 0.011 | 40 | consistent |
| effect-outerglow | effects | kernel | 1 | 0.012 | 40 | consistent |
| effect-innerglow | effects | kernel | 1 | 0.002 | 40 | consistent |
| effect-innershadow | effects | kernel | 1 | 0.004 | 40 | consistent |
| effect-stack | effects | kernel | 1 | 0.039 | 40 | consistent |

## Worst pixels
- **hsv-identity** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **hsv-master** worst=12 at (59, 42): expected [250, 158, 161, 255], actual [255, 146, 149, 255]
    - variant hsv-direct: worst=1
- **hsv-reds** worst=14 at (26, 21): expected [118, 119, 114, 255], actual [104, 105, 100, 255]
    - variant hsv-direct: worst=1
- **levels-identity** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **levels-work** worst=0 at (63, 47): expected [245, 245, 245, 255], actual [245, 245, 245, 255]
    - variant levels-gpu1024: worst=0
- **levels-clip** worst=0 at (63, 47): expected [243, 255, 255, 255], actual [243, 255, 255, 255]
- **curves-identity** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **curves-s** worst=0 at (63, 47): expected [250, 255, 255, 255], actual [250, 255, 255, 255]
- **exposure-identity** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **exposure-up** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
    - variant exposure-cube33: worst=2
- **gradientmap-default** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
    - variant gradientmap-cube33: worst=1
- **gradientmap-duotone** worst=0 at (63, 47): expected [31, 10, 89, 255], actual [31, 10, 89, 255]
    - variant gradientmap-cube33: worst=2
- **gradientmap-reversed-bw** worst=0 at (63, 47): expected [0, 0, 0, 255], actual [0, 0, 0, 255]
    - variant gradientmap-cube33: worst=1
- **gradientmap-warm-end** worst=0 at (63, 47): expected [255, 128, 0, 255], actual [255, 128, 0, 255]
    - variant gradientmap-cube33: worst=1
- **grain-default** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **grain-coarse** worst=0 at (63, 47): expected [251, 251, 251, 255], actual [251, 251, 251, 255]
- **addnoise-uniform** worst=0 at (63, 47): expected [246, 249, 255, 255], actual [246, 249, 255, 255]
- **addnoise-gaussian-mono** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **gaussianblur-min** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **gaussianblur-medium** worst=4 at (58, 0): expected [231, 16, 120, 128], actual [227, 16, 119, 129]
    - variant gaussian-clamped: worst=63
- **motionblur-min** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **motionblur-30deg** worst=73 at (62, 47): expected [251, 242, 148, 57], actual [252, 239, 75, 78]
    - variant motion-plus30: worst=73
    - variant motion-minus30: worst=196
- **invert-chart** worst=0 at (63, 47): expected [0, 0, 0, 255], actual [0, 0, 0, 255]
- **invert-alpha** worst=1 at (52, 39): expected [47, 59, 91, 210], actual [47, 60, 91, 210]
- **blackwhite-default** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
    - variant blackwhite-cube33: worst=1
- **blackwhite-tinted** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
    - variant blackwhite-cube33: worst=6
- **colorbalance-identity** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **colorbalance-warm** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
    - variant blackwhite-cube33: worst=5
- **colorbalance-noluminosity** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **control-base** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **control-identity-normal** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **effect-coloroverlay** worst=1 at (31, 28): expected [240, 133, 117, 255], actual [240, 133, 118, 255]
- **effect-stroke-outside** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **effect-stroke-inside** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **effect-shadow-hard** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **effect-shadow-ang180** worst=0 at (63, 47): expected [255, 255, 255, 255], actual [255, 255, 255, 255]
- **effect-shadow-blur** worst=1 at (32, 32): expected [76, 95, 0, 255], actual [75, 94, 0, 255]
- **effect-outerglow** worst=1 at (30, 30): expected [166, 177, 165, 255], actual [166, 178, 165, 255]
- **effect-innerglow** worst=1 at (35, 26): expected [234, 250, 255, 255], actual [235, 250, 255, 255]
- **effect-innershadow** worst=1 at (32, 27): expected [250, 250, 250, 255], actual [251, 251, 251, 255]
- **effect-stack** worst=1 at (33, 26): expected [140, 140, 204, 255], actual [141, 141, 204, 255]
