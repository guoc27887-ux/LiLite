#!/bin/bash
cd ~/workspace/lilite-ios18-compat
RUN=44435997500
if gh run watch $RUN --exit-status > /tmp/fix-watch.log 2>&1; then
  echo "BUILD SUCCESS"
  rm -rf /tmp/fix-ipa && mkdir -p /tmp/fix-ipa
  gh run download $RUN -n lilite-ios18-unsigned-ipa -D /tmp/fix-ipa 2>&1 | tail -1
  IPA=$(find /tmp/fix-ipa -name "*.ipa" | head -1)
  echo "artifact: $IPA $(du -h "$IPA" | cut -f1)"
  cp "$IPA" ~/workspace/your_files/lilite-ios18-1.0.13-unsigned.ipa
  python3 - << 'PYEOF'
import zipfile, plistlib
z = zipfile.ZipFile('/home/hatch/workspace/your_files/lilite-ios18-1.0.13-unsigned.ipa')
name = [n for n in z.namelist() if n.endswith('.app/Info.plist')][0]
p = plistlib.loads(z.read(name))
print('version:', p.get('CFBundleShortVersionString'), 'build:', p.get('CFBundleVersion'), 'minOS:', p.get('MinimumOSVersion'), 'bundle:', p.get('CFBundleIdentifier'))
PYEOF
else
  echo "BUILD FAILED"
  rm -rf /tmp/fix-log && mkdir -p /tmp/fix-log
  gh run download $RUN -n ios18-build-log -D /tmp/fix-log 2>&1 | tail -1
  find /tmp/fix-log -type f | head -3
  grep -h "error:" $(find /tmp/fix-log -type f | head -2) 2>/dev/null | sort -u | head -15
fi
