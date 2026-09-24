# Bash-Scripts

Helper scripts for working with containerized ARCOS (Arrcus OS) lab topologies.

## lab.sh

A single tool for managing a Docker-based ARCOS lab: bulk config reload, interface
enable/disable, IPv4 address changes, subinterface add/delete, and interface inspection.

The node list and the set of unsupported interfaces are read from `topo.json`, so the
script adapts to a different topology without editing.

### Requirements

- `bash`, `docker`, `jq`, `awk`, `sed`
- Lab containers already running (for example, brought up with `auto_docker.sh`)
- `confd_cli` available inside each container

### Setup

`lab.sh` `cd`s into its own directory and expects these files next to it:

```
lab.sh
topo.json      # topology: .ContainerName[] and .InterConnect[]
L1.cfg         # one <node>.cfg per container name in topo.json
L2.cfg
...
```

`topo.json` format (the fields `lab.sh` uses):

```json
{
  "ContainerName": ["L1", "S1"],
  "InterConnect":  ["L1_swp19:S1_swp5"]
}
```

Copy `lab.sh` into your topology directory, or symlink it there:

```bash
cp lab.sh ~/path/to/topology/
cd ~/path/to/topology && ./lab.sh nodes
```

### Usage

```
./lab.sh <command> <args...>
```

| Command | Arguments | Description |
|---|---|---|
| `reload` | — | Load and commit every node's `<node>.cfg`, then verify interfaces and ISIS adjacency |
| `enable` | `<node> <ifname> <true\|false>` | Administratively enable or disable an interface |
| `set-ip` | `<node> <ifname> <subif> <new_ip> <prefix>` | Replace a subinterface's IPv4 address (the current IP is looked up automatically) |
| `add-subif` | `<node> <ifname> <subif_id> <ip> <prefix>` | Create an enabled subinterface with an IPv4 address |
| `del-subif` | `<node> <ifname> <subif_id>` | Delete a subinterface |
| `show` | `<node> <ifname>` | Show the interface's running config |
| `show detail` | `<node> <ifname>` | Show full operational interface state |
| `nodes` | — | List nodes from `topo.json` |
| `bad-ifaces` | — | List interfaces in `topo.json` numbered above `swp32` |

### Examples

```bash
# Load all configs after a fresh bring-up
./lab.sh reload

# Shut and re-enable a link
./lab.sh enable L1 swp19 false
./lab.sh enable L1 swp19 true

# Change the IP on swp19.0
./lab.sh set-ip L1 swp19 0 10.1.1.1 30

# Add and remove a subinterface
./lab.sh add-subif L1 swp9 10 192.168.10.1 24
./lab.sh del-subif L1 swp9 10

# Inspect an interface
./lab.sh show L1 swp19
./lab.sh show detail L1 swp19
```

### What `reload` does

1. Removes the `version "..."` header line, which `load merge` rejects.
2. Removes interfaces above `swp32`. The container platform (`FF_CONTAINER`) supports
   only about 32 ports, so these interfaces fail with `Invalid ifname`. Both the top-level
   `interface swpNN` stanza and any nested reference to it (for example, under the ISIS
   config) are removed. A leftover reference makes the commit fail with an
   illegal-reference error.
3. Copies each config into its container and runs `load merge` + `commit`, one node at a
   time. If the database is locked, it retries up to 5 times, 10 seconds apart.
4. Lists the loaded interfaces on each node and runs `show isis adjacency` on the first
   node.

Configs are staged in `/tmp/<node>_reload.cfg`. The original `.cfg` files are never
modified.

`auto_docker.sh` does not load configs, so run `./lab.sh reload` after every fresh
bring-up.

### Error handling

`confd_cli` exits with `0` even when a command or commit fails, so `lab.sh` checks the
output text. A command counts as failed if any output line starts with `Error`,
`Aborted`, `Failed`, `syntax error`, or `%`. The exception is
`% No modifications to commit.`, which is treated as a harmless no-op. A failed
`docker exec` (for example, a wrong container name) is also reported. In both cases the
command exits with `1`.

Commands are piped to `docker exec -i <node> confd_cli -u admin -C -N`
(non-interactive, Cisco-style CLI). This avoids the async system messages that can
corrupt input in an interactive session.
