# Verification: an independent oracle for the compositing engine

The Windows port is checked against a *separate* implementation, not against itself.

| File | What it is |
|---|---|
| \`comp_reference.py\` | NumPy implementation of the 24 blend modes and W3C source-over compositing in sRGB, plus a \`.comp\` writer/reader that follows \`docs/project-format.md\` |
| \`make_fixtures.py\` | Builds \`fixtures/*.comp\` and the reference PNG each one must render to |
| \`compare.py\` | Pixel comparison with a tolerance, exit code 1 on mismatch |
| \`acceptance.py\` | Renders every fixture with \`compc\` and compares against the reference |

## Run it

\`\`\`powershell
$py = "C:\\Users\\leoevan\\.dsh\\dsh-runtimes\\dsh-primary-runtime\\dependencies\\python\\python.exe"
& $py tools\\verify\\make_fixtures.py
& $py tools\\verify\\acceptance.py
\`\`\`

Fixtures cover: all 24 blend modes over an opaque ramp (with pure black and pure white probes so
dodging and burning modes hit their boundaries), an alpha ramp at 0.75 layer opacity, a gray layer
mask, folder opacity multiplying into two children, an Invert adjustment layer, and a demo document
for the editor.

Blend math runs in sRGB, matching \`SeparableBlend.swift\`: Core Image would otherwise blend in a
linear space, which is wrong for Color Dodge and Color Burn.
