#!/usr/bin/env python3
"""Rewrite absolute symlinks inside a sysroot so they resolve *within* it.

WHY THIS IS NECESSARY
=====================
A rootfs is full of absolute symlinks. On the target, `/usr/lib/libfoo.so`
pointing at `/lib/libfoo.so.1` is correct. Copy that tree to your build host as a
sysroot at `/home/you/build/sysroots/board/`, and the same symlink now points at
your *host's* `/lib/libfoo.so.1`.

Three things can then happen, in increasing order of nastiness:

1. Nothing is there, the link dangles, and the linker reports a missing library
   that you can plainly see in the sysroot. Confusing, but at least it fails.
2. Your host has a file of that name for a *different architecture*. The linker
   reads it and says "incompatible file format". You now suspect your compiler
   flags, which are fine.
3. Your host has a file of that name for the *same* architecture but a different
   version — very likely if you cross-compile x86_64→x86_64 with a different libc.
   Everything links successfully and the binary misbehaves on the target. This is
   the worst outcome in the whole cross-compilation problem space, because there is
   no error message anywhere.

Making the links relative and sysroot-internal removes all three at once. The
sysroot then works at any path, on any host, and can be tarred up and moved.

WHY NOT `symlinks -c`
=====================
The standard `symlinks` utility converts absolute links to relative ones *with
respect to the filesystem it is running on*. Inside a sysroot that is the wrong
frame of reference: it would resolve `/lib/libfoo.so.1` against the host root and
generate a chain of `../../..` that climbs out of the sysroot and lands on the
host. This script treats the sysroot as the root — which is what the compiler's
`--sysroot` also does — so the two agree.

RUN IT AFTER acquisition and BEFORE compiling. `make sysroot` does this for you
for every provider, which is precisely why providers do not each have to.

USAGE
    relocate-symlinks.py <sysroot> [--dry-run] [--quiet]
"""

import argparse
import os
import sys


def classify(sysroot: str, link_path: str, target: str):
    """Decide what a symlink should point to, expressed as an absolute host path.

    Returns (intended_abs_path, reason) or (None, reason) to leave it alone.

    The two cases are genuinely different and conflating them is a bug:

    * An ABSOLUTE target is written in the target machine's frame of reference.
      '/lib/x' means "the sysroot's /lib/x", so we reinterpret it against the
      sysroot. This is the common case and the whole point of the script.

    * A RELATIVE target is already frame-independent and usually correct — e.g.
      'libfoo.so.1' next to 'libfoo.so'. We only touch it if it escapes the
      sysroot, which happens when a rootfs was assembled with links like
      '../../../lib/x' that only resolved because of where they sat originally.
    """
    if os.path.isabs(target):
        # os.path.join discards everything before an absolute component, so
        # concatenate manually. normpath then collapses any '..' inside the target
        # itself, which matters because a crafted '/usr/../../etc' must not be
        # allowed to escape.
        intended = os.path.normpath(sysroot + os.sep + target.lstrip("/"))
        return intended, "absolute"

    resolved = os.path.normpath(os.path.join(os.path.dirname(link_path), target))
    if resolved == sysroot or resolved.startswith(sysroot + os.sep):
        return None, "relative-and-contained"

    # Escapes. Strip the leading '..' hops and reinterpret the remainder as
    # sysroot-rooted, which recovers the intent in every real case observed
    # (they are almost always multiarch links assembled at a different depth).
    parts = [p for p in target.split("/") if p and p != "."]
    while parts and parts[0] == "..":
        parts.pop(0)
    if not parts:
        return None, "relative-escaping-but-empty"
    return os.path.normpath(os.path.join(sysroot, *parts)), "relative-escaping"


def relocate(sysroot: str, dry_run: bool = False, quiet: bool = False) -> int:
    sysroot = os.path.abspath(sysroot).rstrip(os.sep) or os.sep
    if not os.path.isdir(sysroot):
        print(f"relocate-symlinks: not a directory: {sysroot}", file=sys.stderr)
        return -1

    # Refuse to operate on the live root filesystem. For a native target,
    # SYSROOT_DIR is legitimately '/', and rewriting every symlink on the build
    # machine would be catastrophic and irreversible. Normalisation is meaningless
    # there anyway: a native sysroot is already at the path its links assume.
    if sysroot == os.sep:
        print("relocate-symlinks: refusing to rewrite symlinks on '/' "
              "(a native sysroot needs no relocation).", file=sys.stderr)
        return 0

    fixed = dangling = skipped = 0

    # followlinks=False so we never recurse *through* a symlinked directory. With
    # it on, a self-referential link (common: /usr/lib -> . in some images) makes
    # this walk infinite.
    for root, dirs, files in os.walk(sysroot, followlinks=False):
        for name in list(files) + list(dirs):
            path = os.path.join(root, name)
            if not os.path.islink(path):
                continue

            target = os.readlink(path)
            intended, reason = classify(sysroot, path, target)
            if intended is None:
                skipped += 1
                continue

            # A link whose destination does not exist in the sysroot is left as it
            # is. Rewriting it would convert a visible dangling link into a
            # *differently* dangling link, gaining nothing; and the honest signal
            # ("this sysroot is missing something") is worth preserving. These are
            # usually links into /proc, /dev, or a package that was excluded.
            if not os.path.exists(intended):
                dangling += 1
                if not quiet:
                    rel = os.path.relpath(path, sysroot)
                    print(f"  dangling (left alone): /{rel} -> {target}")
                continue

            new_target = os.path.relpath(intended, os.path.dirname(path))
            if new_target == target:
                skipped += 1
                continue

            if not quiet:
                rel = os.path.relpath(path, sysroot)
                print(f"  /{rel}: {target} -> {new_target}  [{reason}]")

            if not dry_run:
                # Replace atomically-ish: unlink then symlink. A crash between the
                # two loses one link, which `make sysroot` repairs on the next run.
                # os.symlink cannot overwrite, so the unlink is required.
                try:
                    os.unlink(path)
                    os.symlink(new_target, path)
                except OSError as exc:
                    print(f"relocate-symlinks: cannot rewrite {path}: {exc}",
                          file=sys.stderr)
                    print("  (a read-only sysroot? use SYSROOT_PROVIDER=dir with "
                          "mode=copy, or SYSROOT_PROVIDER=none to skip this step)",
                          file=sys.stderr)
                    return -1
            fixed += 1

    verb = "would rewrite" if dry_run else "rewrote"
    print(f"relocate-symlinks: {verb} {fixed} symlink(s); "
          f"{skipped} already fine; {dangling} dangling left as-is")
    return fixed


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Make a sysroot's symlinks resolve within the sysroot, "
                    "so it works at any path on any host.")
    ap.add_argument("sysroot")
    ap.add_argument("--dry-run", action="store_true",
                    help="report what would change, change nothing")
    ap.add_argument("--quiet", action="store_true",
                    help="totals only, no per-link output")
    args = ap.parse_args()
    rc = relocate(args.sysroot, args.dry_run, args.quiet)
    return 1 if rc < 0 else 0


if __name__ == "__main__":
    sys.exit(main())
