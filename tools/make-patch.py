#!/usr/bin/env python3
"""Tidewall's update patches: only the files that changed between two releases.

  make-patch.py <previous Tidewall.app> <new Tidewall.app> <out.zip>

Writes out.zip holding Tidewall.app/<every file that's new or different> and deleted.txt (the paths, inside the app,
of files the new release no longer has), then checks it exactly the way the app's updater will use it: a clone of the
previous app, the zip unpacked over it, the deleted files removed, and the result's code-signature hash (which seals
every file in the bundle) compared with the new app's. Exits non-zero, and leaves no zip, if that doesn't match: the
release then ships without a patch and every copy fetches the whole thing, as before.
"""
import hashlib, os, shutil, stat, subprocess, sys, tempfile


def files(root):
    out = {}
    for d, dirs, fs in os.walk(root):
        for f in fs + [x for x in dirs if os.path.islink(os.path.join(d, x))]:
            p = os.path.join(d, f)
            r = os.path.relpath(p, root)
            st = os.lstat(p)
            if stat.S_ISLNK(st.st_mode):
                out[r] = ("link", os.readlink(p))
            else:
                h = hashlib.sha256()
                with open(p, "rb") as fh:
                    for b in iter(lambda: fh.read(1 << 20), b""):
                        h.update(b)
                out[r] = (h.hexdigest(), stat.S_IMODE(st.st_mode))
    return out


def cdhash(app):
    r = subprocess.run(["codesign", "-dv", "--verbose=4", app], capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if line.startswith("CDHash="):
            return line.split("=", 1)[1].strip().lower()
    return None


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    old, new, out = sys.argv[1:]
    a, b = files(old), files(new)
    changed = [r for r in b if a.get(r) != b[r]]
    deleted = sorted(r for r in a if r not in b)
    work = tempfile.mkdtemp()
    try:
        pdir = os.path.join(work, "patch")
        os.makedirs(os.path.join(pdir, "Tidewall.app"))
        for r in changed:
            src, dst = os.path.join(new, r), os.path.join(pdir, "Tidewall.app", r)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            if os.path.islink(src):
                os.symlink(os.readlink(src), dst)
            else:
                shutil.copy2(src, dst)
        with open(os.path.join(pdir, "deleted.txt"), "w") as fh:
            fh.write("".join(r + "\n" for r in deleted))
        tmpzip = os.path.join(work, "patch.zip")
        subprocess.run(["ditto", "-c", "-k", pdir, tmpzip], check=True)

        # the updater's way: clone the previous app, unpack over it, remove the deleted, compare the seal
        stage = os.path.join(work, "stage")
        os.makedirs(stage)
        app = os.path.join(stage, "Tidewall.app")
        if subprocess.run(["cp", "-cR", old, app]).returncode != 0:
            subprocess.run(["ditto", old, app], check=True)
        subprocess.run(["ditto", "-x", "-k", tmpzip, stage], check=True)
        for r in deleted:
            p = os.path.join(app, r)
            if os.path.islink(p) or os.path.isfile(p):
                os.remove(p)
            elif os.path.isdir(p):
                shutil.rmtree(p)
        os.remove(os.path.join(stage, "deleted.txt"))
        if subprocess.run(["codesign", "--verify", "--deep", "--strict", app]).returncode != 0:
            sys.exit("the patched copy's code signature doesn't verify")
        want, got = cdhash(new), cdhash(app)
        if not want or want != got:
            sys.exit(f"the patched copy isn't the release (cdhash {got} != {want})")
        shutil.move(tmpzip, out)
        size = os.path.getsize(out)
        print(f"patch: {len(changed)} changed, {len(deleted)} removed, {size / 1e6:.2f} MB; cdhash {want}")
    finally:
        shutil.rmtree(work, ignore_errors=True)


main()
