#!/usr/bin/env bash
set -euo pipefail
# set -x 

# This is a cleaner, simplified version of the preseed.yaml + inventory.ini 
# generator that runs in 3 passes instead of the complex, snaggly, one-pass
# version I started with. 

# Tunables begin here
microcloud_session_passphrase="${microcloud_session_passphrase:-$(openssl rand -hex 12)}"

# This is an SSH key known to Ansible that is used to SSH into the nodes
# so packages and other configuration can be done, in this case, Juju ssh key
ansible_ssh_private_key_file="/home/desrod/.local/share/juju/ssh/juju_id_rsa"
maas_node_tag=${maas_node_tag:-compute}
microcloud_preseed_timeout=600
ovn_network_interface=enp0s18
ipv4_gateway="192.168.120.1/24"
ipv4_range="192.168.120.240-192.168.120.254"

###############################################################################
# Extract all targeted cluster nodes from MAAS. Update tag names as needed.
###############################################################################

nodes_json=$(maas admin machines read | jq --arg tag "$maas_node_tag" '
  def first_ip:
    [(.interface_set[]?.links[]?.ip_address) | select(.)] | first // empty;

  [ .[]
    | select(.status_name == "Deployed")
    | select((.tag_names // []) | index($tag))
    | {
        hostname: (.hostname // .system_id),
        ip: first_ip
      }
    | select(.ip != null)
  ]
  | sort_by(.hostname)
')

node_count=$(jq length <<<"$nodes_json")

if [[ "$node_count" -eq 0 ]]; then
  echo "ERROR: No deployed MAAS machines matching tag '$maas_node_tag'"
  exit 1
fi

###############################################################################
# Generate the preseed.yaml needed to bootstrap the nodes
###############################################################################

jq -n \
  --argjson nodes    "$nodes_json"                    \
  --arg passphrase   "$microcloud_session_passphrase" \
  --argjson timeout  "$microcloud_preseed_timeout"    \
  --arg ovn_iface    "$ovn_network_interface"         \
  --arg ipv4_gateway "$ipv4_gateway"                  \
  --arg ipv4_range   "$ipv4_range" '

def ceph_disks:
[
  {path:"/dev/vdb", wipe:true},
  {path:"/dev/vdc", wipe:true}
];

{
  initiator_address: $nodes[0].ip,
  session_passphrase: $passphrase,
  session_timeout: $timeout,
  lookup_timeout: $timeout,

  systems: ($nodes | map({
    name: .hostname,
    address: .ip,
    ovn_uplink_interface: $ovn_iface,
    ovn_underlay_ip: .ip,
    storage: { ceph: ceph_disks }
  })),

  ceph: {cephfs:true},

  ovn: {
    ipv4_gateway: $ipv4_gateway,
    ipv4_range: $ipv4_range
  }
}
' | yq -y '.' > preseed.yaml

###############################################################################
# Generate a dynamic Ansible inventory of all tagged, targeted nodes
###############################################################################

{
  echo "[microcloud]"
  jq -r '.[] | "\(.hostname) ansible_host=\(.ip)"' <<<"$nodes_json"
  echo
  echo "[microcloud:vars]"
  echo "ansible_user=ubuntu"
  echo "ansible_become=true"
  echo "ansible_ssh_private_key_file=${ansible_ssh_private_key_file}"
  echo "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
} > inventory.ini

