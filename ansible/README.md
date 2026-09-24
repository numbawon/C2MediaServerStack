# Ansible

Plain CLI, no AWX/Semaphore, that's a deliberate call for a 3-machine cluster
one person administers, not a gap. See the runbook for the reasoning.

## Setup

Installed on `C2Storage` only (it's agentless -- nothing runs on the
managed nodes beyond the Python they already have):

```
sudo pacman -S ansible
```

Everything below runs from this directory.

## Inventory

`inventory.ini` -- the three machines, grouped as `manager` (C2Storage),
`workers` (the two NUCs) and `cluster` (both). SSH keys between all three
were already set up before Ansible existed, so there's nothing extra to
configure for connectivity.

## Running a playbook

```
ansible-playbook playbooks/<name>.yml --ask-become-pass
```

`--ask-become-pass` prompts once, interactively, and that one password
covers `sudo` on all three hosts for the run -- the same wall every manual
multi-host task hit all night, solved by asking once instead of three
times in three separate terminals.

Check what a playbook *would* do without changing anything:

```
ansible-playbook playbooks/<name>.yml --ask-become-pass --check --diff
```

## Playbooks

- **`docker-insecure-registry.yml`** -- `/etc/docker/daemon.json` on all
  three nodes, pointing at the LAN registry. Reproduces the real manual
  work from 2026-09-23/24, done right the first time: creates `/etc/docker`
  if missing (the actual failure point that night), writes the file in the
  exact format already on disk so a clean run is a true no-op, and only
  restarts docker when the file's content genuinely changed.
