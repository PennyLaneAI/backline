#!/usr/bin/env bash
#
# merge-probed-facts.sh — update an existing target description with freshly probed
# facts, leaving every other line untouched.
#
# USAGE
#   merge-probed-facts.sh [--fresh] <existing.conf> <freshly-probed.conf>
#
# Writes the merged description to stdout. Writes a one-line-per-key account of what
# changed, what was kept and what could not be determined to stderr.
#
# --fresh discards the existing description and emits the probed one verbatim, for a
# machine whose identity has changed rather than a machine that has been re-probed. It
# lives here, rather than as a branch in the caller, so that both modes are one command
# away from a test.
#
# WHAT A "FACT" IS
# A description holds two kinds of value. The keys in PROBE_FACTS below are read off
# the machine: its architecture, its libc, its ABI ceilings, the path of its loader.
# Everything else is a decision no probe can make. Where the sysroot comes from, whether
# to tune for one exact CPU, which C++ standard the SOURCE needs: none of those are
# properties of the hardware, and a machine cannot answer them.
#
# So only the facts are replaced. Comments, ordering, and every other assignment survive,
# which is what makes re-probing a machine safe on a description somebody has tuned.
#
# TARGET_GPU_ARCH is deliberately NOT in the list, even though the probe can read it off
# the machine and pre-fills it on a fresh description. A bundle may target a card other
# than the one the probed machine holds — that is the whole point of naming an offload
# architecture — so an override has to outlive the next probe. The probe records what it
# saw as a '# probe-gpu-arch:' comment instead, and probe-over-ssh.sh reports a
# disagreement between the two rather than resolving it.
#
# TWO RULES THE CALLER DEPENDS ON
#   * An empty probe result means "could not determine", never "the machine has none".
#     A libc version or ABI ceiling that comes back blank leaves the existing value in
#     place, because an empty ceiling DISABLES the check that uses it.
#   * A fact the existing description does not mention is appended, so a description
#     written before a fact existed gains it.

set -uo pipefail

FRESH=0
if [[ ${1:-} == --fresh ]]; then FRESH=1; shift; fi

OLD=${1:?usage: merge-probed-facts.sh [--fresh] <existing.conf> <fresh.conf>}
NEW=${2:?usage: merge-probed-facts.sh [--fresh] <existing.conf> <fresh.conf>}

[[ -r $OLD ]] || { printf 'ERROR: cannot read %s\n' "$OLD" >&2; exit 1; }
[[ -r $NEW ]] || { printf 'ERROR: cannot read %s\n' "$NEW" >&2; exit 1; }

# One line, deliberately: the membership test below is a `case` against " $PROBE_FACTS ",
# and a newline inside the list would stop a key adjacent to it from matching.
PROBE_FACTS="TARGET_ARCH TARGET_ENDIAN TARGET_TRIPLE TARGET_CPU_FLAG TARGET_LIBC TARGET_LIBC_VERSION TARGET_CXXABI_MAX TARGET_DYNAMIC_LINKER"

fresh_value() { sed -n "s/^$1=//p" "$NEW" | head -1; }

if [[ $FRESH -eq 1 ]]; then
  cat "$NEW"
  printf '  replaced  the whole description, as --fresh asked. Every decision the old one\n' >&2
  printf '            carried is gone: provider, TARGET_CPU, flags, comments.\n' >&2
  exit 0
fi

seen=""
while IFS= read -r line || [[ -n $line ]]; do
  # No '=' means a comment or a blank line. Guarding here rather than in the membership
  # test below, because an empty key would match the pattern's separating spaces.
  case $line in
    *=*) ;;
    *)   printf '%s\n' "$line"; continue ;;
  esac

  key=${line%%=*}
  case " $PROBE_FACTS " in
    *" $key "*) ;;
    *) printf '%s\n' "$line"; continue ;;
  esac

  seen="$seen $key"
  old_v=${line#*=}
  new_v=$(fresh_value "$key")

  if [[ -z $new_v && -n $old_v ]]; then
    printf '%s\n' "$line"
    printf '  kept     %-24s the probe could not determine it\n' "$key" >&2
  elif [[ $new_v != "$old_v" ]]; then
    printf '%s=%s\n' "$key" "$new_v"
    printf '  updated  %-24s %s -> %s\n' "$key" "${old_v:-<empty>}" "${new_v:-<empty>}" >&2
  else
    printf '%s\n' "$line"
  fi
done < "$OLD"

for key in $PROBE_FACTS; do
  case " $seen " in *" $key "*) continue ;; esac
  new_v=$(fresh_value "$key")
  [[ -n $new_v ]] || continue
  printf '\n# Added by make probe: this description predates the key.\n%s=%s\n' "$key" "$new_v"
  printf '  added    %-24s %s\n' "$key" "$new_v" >&2
done
