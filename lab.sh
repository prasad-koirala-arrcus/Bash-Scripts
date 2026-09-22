#!/usr/bin/env bash
# Combined dev-upf lab tool: config reload + interface toggling in one file.
# Node list and "bad" (>32) interfaces are derived from topo.json, so this
# adapts automatically if the topology changes -- no hardcoded node/iface
# names to edit by hand.
set -uo pipefail
cd "$(dirname "$0")"

TOPO="topo.json"
MAX_PORT=32

# ---------------------------------------------------------------------------
# topology helpers
# ---------------------------------------------------------------------------

nodes() {
  jq -r '.ContainerName[]' "$TOPO"
}

# every "<node>_swpNN" mentioned in InterConnect where NN > MAX_PORT,
# printed as "<node> swpNN" -- these don't exist on the FF_CONTAINER
# virtual ASIC (~32 ports) and must be stripped before loading.
bad_ifaces() {
  jq -r '.InterConnect[]' "$TOPO" \
    | tr ':' '\n' \
    | while read -r end; do
        node="${end%%_swp*}"
        port="${end#*_swp}"
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port > MAX_PORT )); then
          echo "$node swp$port"
        fi
      done
}

# ---------------------------------------------------------------------------
# config reload (formerly reload_all.sh)
# ---------------------------------------------------------------------------

strip_version() {
  local src="$1" out="$2"
  sed '/^version "/d' "$src" > "$out"
}

# Strips every "interface <ifn>" stanza regardless of indent depth -- needs
# to catch both the top-level "interface swpNN" stanza (zero indent) AND any
# nested reference to it, e.g. under "network-instance ... protocol ISIS
# ... interface swpNN" (indented) -- leaving the latter in place aborts
# commit with an illegal-reference error even once the top-level stanza
# itself is gone. Each stanza is terminated by a "!" at the same indent
# level it opened with.
strip_iface() {
  local src="$1" out="$2" ifn="$3"
  awk -v ifn="$ifn" '
    BEGIN { skip=0; term="" }
    {
      if (!skip) {
        if ($0 ~ "^ *interface " ifn "($| )") {
          match($0, "^ *")
          term = substr($0, 1, RLENGTH) "!"
          skip = 1
          next
        }
        print
        next
      }
      if ($0 == term) { skip = 0 }
      next
    }
  ' "$src" > "$out"
}

load_node() {
  local node="$1" cfgfile="$2"
  docker cp "$cfgfile" "${node}:/tmp/${node}.cfg"
  local attempt out
  for attempt in 1 2 3 4 5; do
    out="$(printf 'config\nload merge /tmp/%s.cfg\ncommit\nend\n' "$node" \
      | docker exec -i "$node" confd_cli -u admin -C -N 2>&1)"
    if echo "$out" | grep -q "locked by session"; then
      echo "[$node] db locked, retrying in 10s (attempt $attempt)..."
      sleep 10
      continue
    fi
    break
  done
  echo "=== $node ==="
  echo "$out" | tail -5
}

cmd_reload() {
  local node_list
  node_list="$(nodes)"

  echo "-- stripping version header from all configs --"
  local node
  for node in $node_list; do
    strip_version "${node}.cfg" "/tmp/${node}_noversion.cfg"
    cp "/tmp/${node}_noversion.cfg" "/tmp/${node}_reload.cfg"
  done

  echo "-- stripping known-bad (>${MAX_PORT}) interfaces --"
  while read -r bnode biface; do
    [[ -z "${bnode:-}" ]] && continue
    echo "  $bnode: $biface"
    strip_iface "/tmp/${bnode}_reload.cfg" "/tmp/${bnode}_reload.cfg.tmp" "$biface"
    mv "/tmp/${bnode}_reload.cfg.tmp" "/tmp/${bnode}_reload.cfg"
  done < <(bad_ifaces)

  echo "-- loading configs (one node at a time) --"
  for node in $node_list; do
    load_node "$node" "/tmp/${node}_reload.cfg"
  done

  echo
  echo "-- verifying interfaces loaded --"
  for node in $node_list; do
    echo "=== $node ==="
    printf 'show running-config interface\n' \
      | docker exec -i "$node" confd_cli -u admin -C -N 2>&1 | grep -E "^interface "
  done

  echo
  echo "-- ISIS adjacency check (from first node) --"
  local first_node
  first_node="$(echo "$node_list" | head -1)"
  printf 'show isis adjacency\n' \
    | docker exec -i "$first_node" confd_cli -u admin -C -N 2>&1
}

# ---------------------------------------------------------------------------
# interface toggling (formerly iface_toggle.sh)
# ---------------------------------------------------------------------------

run_cli() {
  local node="$1" cmds="$2"
  local out rc=0
  out="$(printf '%s' "$cmds" | docker exec -i "$node" confd_cli -u admin -C -N 2>&1)" || rc=$?
  printf '%s\n' "$out"
  if [[ "$rc" -ne 0 ]]; then
    echo "lab.sh: docker exec failed on $node (exit $rc)" >&2
    return 1
  fi
  # confd_cli exits 0 even when a config command/commit fails, or when it
  # can't even reach confd (error text is embedded in stdout, not reflected
  # in the exit code) -- catch it here.
  # NB: "% No modifications to commit." is the one benign no-op (e.g.
  # deleting a subinterface that's already gone) -- everything else
  # starting with "Error"/"Aborted"/"Failed"/"syntax error" or any other
  # "% ..." confd error is a real failure and must be flagged.
  local bad_pct
  bad_pct="$(grep -E '^% ' <<<"$out" | grep -vF '% No modifications to commit.' || true)"
  if grep -qiE '^(Error|Aborted|Failed|syntax error)' <<<"$out" || [[ -n "$bad_pct" ]]; then
    echo "lab.sh: commit failed on $node" >&2
    return 1
  fi
}

cmd_enable() {
  local node="$1" ifname="$2" state="$3"
  run_cli "$node" "config
interface $ifname
enabled $state
commit
end
"
}

cmd_set_ip() {
  local node="$1" ifname="$2" subif="$3" new_ip="$4" prefix="$5"
  local cur old_ip
  cur="$(printf 'show running-config interface %s\n' "$ifname" \
    | docker exec -i "$node" confd_cli -u admin -C -N 2>&1)"
  old_ip="$(awk -v sub="$subif" '
    $0 == " subinterface " sub { insub=1; next }
    insub && $0 == " exit" { exit }
    insub && $0 ~ /^  ipv4 address / { print $3; exit }
  ' <<<"$cur")"
  if [[ "$old_ip" == "$new_ip" ]]; then
    echo "lab.sh: $node $ifname subinterface $subif is already $new_ip, nothing to do"
    return 0
  fi
  local remove_old=""
  [[ -n "$old_ip" ]] && remove_old="no ipv4 address $old_ip"
  run_cli "$node" "config
interface $ifname
subinterface $subif
$remove_old
ipv4 address $new_ip
prefix-length $prefix
top
commit
end
"
}

cmd_add_subif() {
  local node="$1" ifname="$2" subif="$3" ip="$4" prefix="$5"
  run_cli "$node" "config
interface $ifname
subinterface $subif
ipv4 address $ip
prefix-length $prefix
enabled true
top
commit
end
"
}

cmd_del_subif() {
  local node="$1" ifname="$2" subif="$3"
  run_cli "$node" "config
interface $ifname
no subinterface $subif
commit
end
"
}

cmd_show() {
  local node ifname
  if [[ "${1:-}" == "detail" ]]; then
    node="$2" ifname="$3"
    run_cli "$node" "show interface $ifname
"
  else
    node="$1" ifname="$2"
    run_cli "$node" "show running-config interface $ifname
"
  fi
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

action="${1:-}"
shift || true
case "$action" in
  reload)     cmd_reload ;;
  enable)     cmd_enable "$@" ;;
  set-ip)     cmd_set_ip "$@" ;;
  add-subif)  cmd_add_subif "$@" ;;
  del-subif)  cmd_del_subif "$@" ;;
  show)       cmd_show "$@" ;;
  nodes)      nodes ;;
  bad-ifaces) bad_ifaces ;;
  *)
    echo "usage: $0 <command> <args...>"
    echo "  reload                                                   reload all node configs from topo.json"
    echo "  enable    <node> <ifname> <true|false>"
    echo "  set-ip    <node> <ifname> <subif> <new_ip> <prefix>             looks up the current IP itself"
    echo "  add-subif <node> <ifname> <subif_id> <ip> <prefix>"
    echo "  del-subif <node> <ifname> <subif_id>"
    echo "  show      <node> <ifname>                                       compact (running-config) view
  show      detail <node> <ifname>                                full operational view"
    echo "  nodes                                                    list nodes from topo.json"
    echo "  bad-ifaces                                                list interfaces >${MAX_PORT} ports found in topo.json"
    exit 1
    ;;
esac
