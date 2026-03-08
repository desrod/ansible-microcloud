# MicroCloud MAAS Bootstrap Generator

This repository contains a small but practical generator for automatically generating the [MicroCloud](https://canonical.com/microcloud) preseed configuration and Ansible inventory file needed to bootstrap a MicroCloud cluster from machines deployed in MAAS.

You can easily repurpose this to work with your baremetal machines as well, but I used MAAS in this case because it was significantly faster to deploy and converge these nodes via Juju.

The goal I had was simple:

> _Take a group of tagged machines already deployed in MAAS and turn them into a working MicroCloud cluster with minimal manual work_

The approach here intentionally keeps things clean and transparent, shell‑driven, and easy to audit**, rather than hiding everything inside a large framework.

------------------------------------------------------------------------

# Simple Overview

The entire workflow I wrote consists of three steps:

1. Discover cluster nodes from MAAS with a targeted tag ("compute" in my case)
2. Generate the `preseed.yaml` needed to bootstrap the cluster for MicroCloud
3. Generate the inventory.ini` needed to drive Ansible to converge the cluster

The resulting files are then used by an Ansible playbook to deploy the
cluster.

    MAAS API (maas admin machines read)
       │
       ▼
    build.sh
       ├── preseed.yaml
       └── inventory.ini
                │
                ▼
         Ansible playbook
                │
                ▼
        MicroCloud cluster

------------------------------------------------------------------------

# Why did I write this

MicroCloud requires a fairly detailed `preseed.yaml` describing:

- Cluster nodes
- Ceph disks
- OVN networking
- Bootstrap node
- Session configuration

When working with MAAS to manage nodes and Juju to manage the models, all of that information already present through the MAAS API, but it isn't directly usable by MicroCloud without some data manipulation.

This script bridges that gap by dynamically generating the required configuration needed by both MicroCloud (`preseed.yaml`) and Ansible (`inventory.ini`).

I have fully tested this from 3 nodes to 15 total nodes in parallel. The timing of convergence was the most difficult part to work out, and after quit eliterally over 500 deployments testing this, I've worked out the cleanest, simplistic way to do this. 

The Ansible playbook is also idempotent, and will remove the snaps, remove the state directories and reinstall them to ensure a clean run end to end.

------------------------------------------------------------------------

# Requirements

The script assumes the following tools are available:

- `maas` via the commandline (eg: running `maas list` should produce valid login API key)
- `jq` - used to mangle the MAAS JSON output into the preseed
- `yq` - used to generate the inventory.ini from MAAS JSON output
- `openssl` - Used to generate a random passphrase at each run
- MAAS API credentials already configured (via the use of `maas login`)

Your machines must already be:

-   In a 'Deployed' state as seen by MAAS 
-   Tagged appropriately in MAAS (I Used `compute` for my cluster)

------------------------------------------------------------------------

# Basic Usage

Generate the MicroCloud configuration files:

``` bash
./build.sh
```

This produces:

    preseed.yaml
    inventory.ini

These are then consumed by the Ansible playbook that deploys the
cluster using the defaults at the top of `build.sh`. If these are not what you need or do not fit your specific network topology or interface names, change them there. 

------------------------------------------------------------------------

# Selecting Nodes via MAAS Tags

The script selects cluster nodes using a MAAS tag.

By default:

    compute

You can override this by setting the `maas_node_tag` environment variable.

Example:

``` bash
maas_node_tag=compute ./build.sh
```

This will:

1. Query MAAS for all machines
2. Select machines that:
    - are in a 'Deployed' state in MAAS
    - contain the tag `compute`
3.  Extract their:
    - hostname
    - primary IP address

These become the nodes used in the MicroCloud cluster.

------------------------------------------------------------------------

# Generated Files

## `preseed.yaml`

This file drives the MicroCloud cluster bootstrap across all lasso'd nodes.

Example structure:

``` yaml
initiator_address: 192.168.120.205
session_passphrase: 1e8c685cbfe16a3d9c5eeade
session_timeout: 600
lookup_timeout: 600

systems:
  - name: maas-node-01
    address: 192.168.120.205
    ovn_uplink_interface: enp0s18
    ovn_underlay_ip: 192.168.120.205
    storage:
      ceph:
        - path: /dev/vdb
          wipe: true
        - path: /dev/vdc
          wipe: true
```

Some important details:

- The first node discovered becomes the initiator of the cluster
- Each node automatically receives the same Ceph disk layout
- OVN networking is configured consistently across all nodes

------------------------------------------------------------------------

## `inventory.ini`

This file is used by Ansible to run the MicroCloud deployment playbook.

Example:

    [microcloud]
    maas-node-01 ansible_host=192.168.120.205
    maas-node-02 ansible_host=192.168.120.206
    maas-node-03 ansible_host=192.168.120.207

    [microcloud:vars]
    ansible_user=ubuntu
    ansible_become=true
    ansible_ssh_private_key_file=/home/me/.local/share/juju/ssh/juju_id_rsa
    ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

This inventory is designed to work directly with the provided Ansible
playbook.

------------------------------------------------------------------------

# Tunable Variables

These variables are defined near the top of `build.sh`:

    Variable                          Purpose
    --------------------------------- --------------------------------
    `maas_node_tag`                   MAAS tag used to select nodes
    `microcloud_session_passphrase`   MicroCloud cluster join secret
    `microcloud_preseed_timeout`      Cluster join timeout (fine-tune here)
    `ovn_network_interface`           Interface used for OVN uplink
    `ipv4_gateway`                    OVN gateway
    `ipv4_range`                      OVN address allocation range

Example override:

``` bash
maas_node_tag=storage ./build.sh
```

------------------------------------------------------------------------

# Ceph Disk Layout

Currently the script assumes each node has:

    /dev/vdb
    /dev/vdc

These disks are wiped and added as Ceph OSDs during cluster creation.

If your hardware differs, modify this section in `build.sh`:

    def ceph_disks:
    [
      {path:"/dev/vdb", wipe:true},
      {path:"/dev/vdc", wipe:true}
    ];

------------------------------------------------------------------------

# Ansible Deployment

After generating the files, run the playbook:

``` bash
ansible-playbook -i inventory.ini compose-cloud.yaml -vv -f 50
```

The playbook will:

1. Remove any existing MicroCloud snaps and state directories
2. Install required MicroCloud snaps (lxd, microcloud, microovn, microceph)
3.  Wait for services to initialize and become ready
4.  Execute `microcloud preseed` passing in the `preseed.yaml` as input
5.  Converge the cluster

In the end, you should get something that looks like: 

    Status: HEALTHY

    ┌──────────────┬─────────────────┬──────┬─────────────────┬────────────────────────┬────────┐
    │     Name     │     Address     │ OSDs │ MicroCeph Units │     MicroOVN Units     │ Status │
    ├──────────────┼─────────────────┼──────┼─────────────────┼────────────────────────┼────────┤
    │ maas-node-24 │ 192.168.120.205 │  2   │   mds,mgr,mon   │ central,chassis,switch │ ONLINE │
    │ maas-node-25 │ 192.168.120.204 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-26 │ 192.168.120.206 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-27 │ 192.168.120.214 │  2   │   mds,mgr,mon   │ central,chassis,switch │ ONLINE │
    │ maas-node-28 │ 192.168.120.208 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-29 │ 192.168.120.216 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-30 │ 192.168.120.207 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-31 │ 192.168.120.209 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-32 │ 192.168.120.213 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-33 │ 192.168.120.211 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-34 │ 192.168.120.212 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-35 │ 192.168.120.210 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-36 │ 192.168.120.217 │  2   │        -        │     chassis,switch     │ ONLINE │
    │ maas-node-37 │ 192.168.120.215 │  2   │   mds,mgr,mon   │ central,chassis,switch │ ONLINE │
    │ maas-node-38 │ 192.168.120.218 │  2   │        -        │     chassis,switch     │ ONLINE │
    └──────────────┴─────────────────┴──────┴─────────────────┴────────────────────────┴────────┘

------------------------------------------------------------------------

# Design Philosophy

This project intentionally favors:

-   Simple shell constructs, no complex shell, easily readable/mutable
-   Readable jq transforms, no Ginsu knives needed here
-   Absolute minimal dependencies to get started
-   Reproducible cluster configuration, can be run as CI/CD if needed

Rather than hiding logic in layers of tooling, the goal here was to keep the cluster generation pipeline visible and easy to modify for any platform or network topology.

------------------------------------------------------------------------

# Contributing

Improvements are welcome, particularly around:

- Automatic Ceph disk detection from MAAS
- Hardware profile support for different chassis or platforms
- IPv6 configuration
- Multi‑rack networking layouts

------------------------------------------------------------------------

# License

GPL v3.0
