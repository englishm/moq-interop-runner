#!/bin/bash
# lib/resolve-config.sh - Resolve the effective run config for a version-pinned pairing.
#
# Layers a role's registration config for an (implementation, role, peer, draft)
# tuple, shallow -> deep:
#
#   base (roles[role].docker) -> versions[draft]
#     -> peer_overrides[peer] -> peer_overrides[peer@draft]
#
# Merge rule (see docs/decisions/003-version-pinned-matrix.md):
#   image  - the deepest layer that specifies one wins
#   env    - object merge; most-specific layer wins per key, other keys accumulate
#   flags  - object merge; most-specific layer wins per switch, others accumulate
#
# Usage (sourced):
#   source lib/resolve-config.sh
#   resolve_config implementations.json moqx relay moxygen draft-16
#     -> {"image":...,"env":{...},"flags":{...},"env_args":[...],"flag_args":[...]}
#
# Direct (testing):
#   ./lib/resolve-config.sh implementations.json moqx relay moxygen draft-16

resolve_config() {
  local config="$1" impl="$2" role="$3" peer="$4" draft="$5"
  jq -c \
    --arg impl "$impl" --arg role "$role" --arg peer "$peer" --arg draft "$draft" '
    # Overlay $ov on $base: image deepest-wins; env/flags object-merge (deepest wins per key).
    def layer($base; $ov):
      { image: ($ov.image // $base.image),
        env:   (($base.env   // {}) + ($ov.env   // {})),
        flags: (($base.flags // {}) + ($ov.flags // {})) };
    # Render a flags map to an argv list: true->bare, array->repeated, scalar->"--k v".
    def flag_args:
      to_entries | map(
        .key as $k |
        if   .value == true  then [$k]
        elif .value == false then []
        elif (.value|type) == "array" then (.value | map([$k, .]) | add)
        else [$k, (.value|tostring)] end
      ) | add // [];
    (.implementations[$impl].roles[$role] // {}) as $r |
    ($r.docker // {}) as $d |
    { image: $d.image, env: ($d.env // {}), flags: ($d.flags // {}) } as $base |
    layer($base; ($r.versions[$draft] // {})) as $l1 |
    layer($l1;   ($r.peer_overrides[$peer] // {})) as $l2 |
    layer($l2;   ($r.peer_overrides[($peer + "@" + $draft)] // {})) as $res0 |
    ($draft | ltrimstr("draft-")) as $dnum |
    # Tier-C convention: always inject MOQT_DRAFT / MOQT_DRAFT_NUM (an entrypoint can
    # translate these to whatever flag the client takes), and expand ${MOQT_DRAFT[_NUM]}
    # placeholders in registration env/flag values for the declarative variant.
    ( (($res0.env // {}) + {"MOQT_DRAFT": $draft, "MOQT_DRAFT_NUM": $dnum})
        | with_entries(.value |= (gsub("\\$\\{MOQT_DRAFT_NUM\\}"; $dnum)
                                  | gsub("\\$\\{MOQT_DRAFT\\}"; $draft))) ) as $env |
    ( ($res0.flags // {})
        | with_entries(.value |= (if type == "string"
            then (gsub("\\$\\{MOQT_DRAFT_NUM\\}"; $dnum) | gsub("\\$\\{MOQT_DRAFT\\}"; $draft))
            else . end)) ) as $flags |
    ($res0 + {env: $env, flags: $flags}) as $res |
    $res + {
      env_args:  ($res.env   | to_entries | map(.key + "=" + .value)),
      flag_args: ($res.flags | flag_args)
    }
  ' "$config"
}

# Allow direct invocation for testing/inspection.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <config.json> <impl> <role> <peer> <draft>" >&2
    exit 1
  fi
  resolve_config "$@"
fi
