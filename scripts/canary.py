#!/usr/bin/env python3
"""Build a local, ad-hoc signed canary with its own identity and icon."""
from datetime import datetime
from pathlib import Path
import json
import plistlib
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
derived = root / 'DerivedData' / 'Canary'
source = root / 'Compositor/Assets.xcassets/AppIcon.appiconset/app-icon-1024-canary.png'
standard = root / 'Compositor/Assets.xcassets/AppIcon.appiconset/Contents.json'
standard_before = standard.read_bytes()
assert source.is_file(), f'Missing canary icon: {source}'
assert all(image.get('filename') != source.name for image in json.loads(standard_before)['images'])
subprocess.run([
    'xcodebuild', '-quiet', '-project', str(root / 'Compositor.xcodeproj'), '-scheme', 'Compositor',
    '-configuration', 'Debug', '-destination', 'platform=macOS', '-derivedDataPath', str(derived),
    'CODE_SIGN_IDENTITY=-', 'CODE_SIGN_STYLE=Manual', 'DEVELOPMENT_TEAM=', 'build',
], check=True, cwd=root)
output = root / 'dist' / ('Compositor-Canary-' + datetime.now().strftime('%Y%m%d-%H%M%S')) / 'Compositor Canary.app'
output.parent.mkdir(parents=True)
subprocess.run(['ditto', str(derived / 'Build/Products/Debug/Compositor.app'), str(output)], check=True)

with tempfile.TemporaryDirectory(prefix='compositor-canary-icon-') as temp:
    temp = Path(temp)
    iconset = temp / 'Canary.iconset'
    iconset.mkdir()
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            target = iconset / f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'
            if pixels == 1024:
                shutil.copyfile(source, target)
            else:
                subprocess.run(['sips', '-z', str(pixels), str(pixels), str(source), '--out', str(target)],
                               check=True, stdout=subprocess.DEVNULL)
    icon = output / 'Contents/Resources/Canary.icns'
    subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(icon)], check=True)
    decoded = temp / 'Verified.iconset'
    subprocess.run(['iconutil', '-c', 'iconset', str(icon), '-o', str(decoded)], check=True)
    # iconutil may re-encode PNG metadata; compare decoded RGBA pixels instead of file bytes.
    verify = r'''import AppKit
func pixels(_ path: String) -> Data {
    let image = NSImage(contentsOfFile: path)!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    precondition(image.width == 1024 && image.height == 1024)
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
        bytesPerRow: 4096, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return Data(bytes: context.data!, count: 4096 * 1024)
}
precondition(pixels(CommandLine.arguments[1]) == pixels(CommandLine.arguments[2]), "Canary icon pixels differ")
'''
    subprocess.run(['swift', '-module-cache-path', str(temp / 'SwiftCache'), '-e', verify,
                    str(source), str(decoded / 'icon_512x512@2x.png')], check=True)
    info = output / 'Contents/Info.plist'
    metadata = plistlib.loads(info.read_bytes())
    # CFBundleIconName points into Assets.car and takes precedence over the standalone canary icon.
    metadata.pop('CFBundleIconName', None)
    metadata.update(CFBundleIconFile='Canary.icns', CFBundleIdentifier='com.wonderassembly.compositor.canary',
                    CFBundleName='Compositor Canary', CFBundleDisplayName='Compositor Canary',
                    SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False)
    info.write_bytes(plistlib.dumps(metadata))
    entitlements = temp / 'Canary.entitlements'
    entitlements.write_text((root / 'Config/Compositor.entitlements').read_text()
                            .replace('$(PRODUCT_BUNDLE_IDENTIFIER)', metadata['CFBundleIdentifier']))
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', '--entitlements', str(entitlements), str(output)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(output)], check=True)
assert standard.read_bytes() == standard_before, 'Standard icon configuration must stay unchanged'
print(output)
