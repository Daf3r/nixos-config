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
# Four things about that map were measured against real `nix flake lock` output
# on 2026-08-11 rather than assumed, because each one is a way to print garbage:
#
#   * A value is usually a node key, but a top-level `follows` writes a PATH
#     instead: `inputs.deep.follows = "dep2/a"` locks as `"deep": ["dep2","a"]`.
#     The whole path has to be walked. Taking its first element lands on the
#     wrong node and reports one input carrying another's revision, which is
#     wrong in the quietest possible way -- a plausible short rev under a real
#     input name.
#   * And every path is relative to the ROOT node, including the ones written
#     inside an internal node. This repo's own lock has two of those --
#     `dms.inputs.nixpkgs = ["nixpkgs"]` and the same under home-manager -- and
#     they mean the root's nixpkgs; read against their own node they would be
#     circular. So a nested path restarts the walk from the root rather than
#     continuing from wherever the walk is standing. Both failures of getting
#     this wrong were measured against locks nix wrote, and both are worse than
#     a wrong rev: one reported the wrong input while dropping the right one,
#     with a clean exit status, and the other -- a segment sharing a name with a
#     root input -- chased itself until jq ran out of memory, inside a systemd
#     unit.
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
# arguments, a lock that cannot be read or parsed, a lock with no root inputs, a
# root input pointing at a node the lock does not have, and a follows path with
# a segment that does not exist. jq's own 2 and 5 are mapped onto 1 so that
# callers have a single number to test -- unlike closure_reboot, which lets jq's
# status through.
#
# Every one of those is an error rather than an empty result or a skipped entry,
# and for one reason. Defaulting a lookup here turns a comparison into "nothing
# moved" with a clean exit status: the exact silence this engine was written to
# remove, restored at the one point where nobody would look for it. A lock this
# cannot read in full is a lock it must not summarise.
inputs_diff() {
  if [ "$#" -ne 2 ]; then
    # Not a formality. The callers run under `set -euo pipefail`, where reaching
    # for an unset $1 is an unbound-variable abort that takes the whole calling
    # script down instead of returning the 1 this function promises.
    printf 'inputs_diff: expected two flake.lock paths, got %s\n' "$#" >&2
    return 1
  fi

  # Checked here rather than left to jq purely for the diagnostic. jq reports a
  # missing file as `Bad JSON in --slurpfile old ...`, which names neither this
  # function nor the real problem, and a lock that is not there yet is the
  # ordinary first-run case for whoever wires this up against a snapshot of the
  # previous lock.
  local f
  for f in "$1" "$2"; do
    if [ ! -r "$f" ]; then
      printf 'inputs_diff: cannot read %s\n' "$f" >&2
      return 1
    fi
  done

  # Captured rather than streamed so that a jq that fails partway cannot leave
  # half an array on stdout. A caller reading a truncated array would get valid
  # JSON describing an update smaller than the one about to be applied.
  local out
  out="$(
    jq -n --slurpfile old "$1" --slurpfile new "$2" '
      # An input value is either a node key or a follows path. Walking a path
      # means: from the node the walk is standing on take input <segment>, and
      # resolve THAT the same way before stepping on. Recursive because a
      # segment can itself be a follows path.
      #
      # The walk starts at $lock.root every time, and that is the whole point:
      # a path is root-relative wherever it is written, so a nested one restarts
      # from the root instead of continuing from the current node. There is no
      # $node parameter for exactly that reason -- there is no other base a
      # caller could legitimately pass, and having one is what made the nested
      # case resolve against the wrong node.
      #
      # Termination rests on the same rule. Resolved against the current node,
      # a segment that shares a name with a root input -- `["pin"]` inside a
      # node that has its own `pin` -- resolves to itself and recurses until jq
      # dies of memory exhaustion. From the root it takes one step and stops.
      def resolve($lock; $ref):
        if ($ref | type) == "array" then
          reduce $ref[] as $seg ($lock.root;
            . as $at
            | ($lock.nodes[$at].inputs[$seg]
               // error("inputs_diff: node \($at) has no input \($seg), following \($ref | tojson)"))
            | resolve($lock; .))
        elif ($ref | type) == "string" then
          $ref
        else
          error("inputs_diff: an input reference that is neither a node key nor a follows path: \($ref | tojson)")
        end;

      # {input name: locked rev}, with "" standing in for a node that has none.
      # A node key that is not in the lock is refused rather than read as "no
      # rev": the empty-rev filter downstream would drop the input, and an input
      # quietly missing from the report is the failure this file exists to stop.
      def revs($lock):
        ($lock.nodes[$lock.root].inputs // {})
        | with_entries(
            .value = (
              resolve($lock; .value) as $k
              | if ($lock.nodes | has($k)) then
                  ($lock.nodes[$k].locked.rev // "")
                else
                  error("inputs_diff: root input points at node \($k), which this lock does not have")
                end));

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
