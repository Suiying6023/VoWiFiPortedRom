#!/usr/bin/env python3
"""Assemble the floss-ims APK from a freshly linked manifest + our dex.

Replaces the old pipeline, which took the upstream compiled APK and edited its
binary AXML in place (patch_targetsdk.py to force targetSdk 33->28, plus string
pool substitutions to inject permissions). That approach could only *replace*
strings, never add them, so RECORD_AUDIO had to be dropped to fit INTERNET --
which is what made outgoing calls impossible.

Rebuilding is safe because the classes we compile reference no resources
(MainActivity is the only resource user and it is excluded from the build), so
there is nothing for a re-link to invalidate.

Usage: pack_apk.py <base.apk from aapt2 link> <dex dir> <lib dir|-> <out.apk>
"""
import os
import sys
import zipfile

# The system loads .so straight out of the APK (extractNativeLibs=false), so
# those entries must be STORED and page-aligned. resources.arsc likewise.
STORED_SUFFIXES = (".so", ".arsc")


def main():
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    base, dexdir, libdir, out = sys.argv[1:5]

    if os.path.exists(out):
        os.remove(out)

    with zipfile.ZipFile(base) as zin, zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zout:
        # 1. manifest + resources.arsc from the aapt2-linked skeleton
        for item in zin.infolist():
            data = zin.read(item.filename)
            zi = zipfile.ZipInfo(item.filename, date_time=item.date_time)
            zi.compress_type = (
                zipfile.ZIP_STORED
                if item.filename.endswith(STORED_SUFFIXES)
                else zipfile.ZIP_DEFLATED
            )
            zout.writestr(zi, data)

        # 2. our dex files, in load order: classes.dex, classes2.dex, ...
        dexes = sorted(
            (f for f in os.listdir(dexdir) if f.endswith(".dex")),
            key=lambda n: (len(n), n),
        )
        if not dexes:
            sys.exit("no .dex found in %s" % dexdir)
        for name in dexes:
            with open(os.path.join(dexdir, name), "rb") as fh:
                zout.writestr(name, fh.read())
        print("packed %d dex: %s" % (len(dexes), ", ".join(dexes)))

        # 3. native libs (Rnnoise, used by the call audio path)
        if libdir != "-":
            n = 0
            for root, _dirs, files in os.walk(libdir):
                for f in files:
                    full = os.path.join(root, f)
                    arc = "lib/" + os.path.relpath(full, libdir).replace(os.sep, "/")
                    zi = zipfile.ZipInfo(arc)
                    zi.compress_type = zipfile.ZIP_STORED
                    with open(full, "rb") as fh:
                        zout.writestr(zi, fh.read())
                    n += 1
            print("packed %d native lib(s)" % n)

    print("wrote %s (%d bytes)" % (out, os.path.getsize(out)))


if __name__ == "__main__":
    main()
