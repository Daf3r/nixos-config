# shellcheck shell=bash
#
# What moved between two flake.lock files.
#
# The engine used to report this as nothing at all: the first real run moved six
# inputs and status.json named none of them. Reading the lock is the reliable
# source -- `nix flake update`'s own stdout is prose meant for a human and it
# changes between nix versions.
#
# Node keys are not input names. The root node's `inputs` map holds the real
# names and points at node keys, and follows-resolution routinely produces keys
# like `nixpkgs_3` -- that is this repo's own lock today, where the input a
# human calls `nixpkgs` lives under node `nixpkgs_3`. Resolving through that map
# is what makes the panel say `nixpkgs` instead of leaking lock internals.
#
# Three things about that map were measured against real `nix flake lock` output
# on 2026-08-11 rather than assumed, because each one is a way to print garbage:
#
#   * A value is usually a node key, but a top-level `follows` writes a PATH
#     instead: `inputs.deep.follows = "dep2/a"` locks as `"deep": ["dep2","a"]`.
#     The whole path has to be walked. Taking its first element lands on the
#     wrong node and reports one input carrying another's revision, which is
#     wrong in the quietest possible way -- a plausible short rev under a real
#     input name.
#   * Not every node has a `rev`. A `path:` input locks as narHash plus
#     lastModified and nothing else. Read without a fallback its rev is null,
#     null never equals null-in-the-other-file either, and the input is reported
#     as moved on every run with `from` and `to` as JSON nulls. Those inputs are
#     skipped instead. The cost is stated plainly: a revless input that really
#     does move is not reported, because there is no short rev to report it
#     with. Every one of the fourteen nodes in this repo's lock carries a rev,
#     so nothing is lost here today, and emitting nulls into the bar to cover a
#     case this repo does not have would be the worse trade.
#   * An input present on only one side has not moved, it has appeared or gone.
#     `dms` and `dms-plugins` both appeared on 2026-08-11. Reporting those as
#     changes with an empty `from` would put a meaningless row in the panel
#     every time an input is added.

# $1 old lock, $2 new lock. stdout: JSON array of {name, kind, from, to},
# sorted by name, one entry per input whose locked revision moved. `from` and
# `to` are the 7-character short revs.
#
# Exit status: 0 with the array on stdout, always followed by a newline so that
# `inputs_diff old new > file` leaves a well-formed text file. 1 for every
# failure, with a message on stderr and nothing at all on stdout: fewer than two
# arguments, a lock that cannot be read or parsed, and a lock with no root
# inputs. jq's own 2 and 5 are mapped onto 1 so that callers have a single
# number to test -- unlike closure_reboot, which lets jq's status through.
#
# The no-root-inputs case is an error rather than an empty result on purpose. It
# is the shape a future lock format would arrive in, and defaulting the lookup
# to `{}` turns every comparison into "nothing moved" with a clean exit status:
# the exact silence this engine was written to remove, restored at the one point
# where nobody would look for it.
inputs_diff() {
  if [ "$#" -ne 2 ]; then
    # Not a formality. The callers run under `set -euo pipefail`, where reaching
    # for an unset $1 is an unbound-variable abort that takes the whole calling
    # script down instead of returning the 1 this function promises.
    printf 'inputs_diff: expected two flake.lock paths, got %s\n' "$#" >&2
    return 1
  fi

  # Captured rather than streamed so that a jq that fails partway cannot leave
  # half an array on stdout. A caller reading a truncated array would get valid
  # JSON describing an update smaller than the one about to be applied.
  local out
  out="$(
    jq -n --slurpfile old "$1" --slurpfile new "$2" '
      # A root input value is either a node key or a follows path. Walking the
      # path means: from the current node take input <segment>, resolve THAT
      # the same way, and continue from where it landed. Recursive because a
      # segment can itself resolve through another follows.
      def resolve($lock; $node; $ref):
        if ($ref | type) == "array"
        then reduce $ref[] as $seg ($node; resolve($lock; .; $lock.nodes[.].inputs[$seg]))
        else $ref
        end;

      # {input name: locked rev}, with "" standing in for a node that has none.
      def revs($lock):
        ($lock.nodes[$lock.root].inputs // {})
        | with_entries(.value = ($lock.nodes[resolve($lock; $lock.root; .value)].locked.rev // ""));

      revs($old[0]) as $o
      | revs($new[0]) as $n
      | if ($o | length) == 0 or ($n | length) == 0 then
          error("inputs_diff: a lock with no root inputs, refusing to report nothing moved")
        else . end
      | [ $o | keys[] as $k
          | select($n | has($k))
          | select($o[$k] != $n[$k])
          | select($o[$k] != "" and $n[$k] != "")
          | {name: $k, kind: "input", from: $o[$k][0:7], to: $n[$k][0:7]} ]'
  )" || return 1

  printf '%s\n' "$out"
}
