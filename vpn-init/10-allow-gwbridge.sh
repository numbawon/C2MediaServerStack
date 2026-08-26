#!/bin/sh
# This container gets two interfaces: eth0 on the `edge` overlay network
# (needed so Traefik can reach qBittorrent by name) and eth1, Docker's
# auto-attached gateway bridge -- which is the container's actual route to
# the internet. The image's own firewall setup only allowlists the ports
# NordVPN's control plane needs (DNS, WireGuard, OpenVPN, API/443) on
# eth0, leaving eth1 with no allow rules at all, so login/connect and
# every VPN control-plane call time out before the tunnel ever comes up.
# Mirror the same allowlist onto eth1.
iptables -A OUTPUT -o eth1 -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -o eth1 -p udp --dport 51820 -j ACCEPT
iptables -A OUTPUT -o eth1 -p tcp --dport 1194 -j ACCEPT
iptables -A OUTPUT -o eth1 -p udp --dport 1194 -j ACCEPT
iptables -A OUTPUT -o eth1 -p tcp --dport 443 -j ACCEPT
