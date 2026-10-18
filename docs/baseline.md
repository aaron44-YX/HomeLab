# Baseline: server setup and hardening

Phase 1 runbook. This records the state of the server after installation and what I did to make it safe to build on.

**Server:** hostname `homelab`, Ubuntu Server 24.04.5 LTS (noble), headless, reached over SSH from my Linux Mint laptop.

## 1. Operating system

```bash
lsb_release -a
```

```
Distributor ID: Ubuntu
Description:    Ubuntu 24.04.5 LTS
Release:        24.04
Codename:       noble
```

**Why 24.04 LTS:** it is a long-term support release, so it gets security updates for years and matches what many employers run.

## 2. Fixed IP address

```bash
ip -4 addr
```

```
2: eno1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ... state UP
    inet 192.168.1.200/24 brd 192.168.1.255 scope global eno1
```

**Why:** a server needs a predictable address. Without one, my SSH config, firewall rules and later services (Nginx, monitoring) would break whenever the router handed out a new IP.

## 3. Firewall (UFW)

```bash
sudo ufw status verbose
```

```
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)

To                         Action      From
22/tcp (OpenSSH)           ALLOW IN    Anywhere
22/tcp (OpenSSH (v6))      ALLOW IN    Anywhere (v6)
```

**Why:** default-deny means a new service is not reachable from the network until I open its port on purpose. Only SSH is open for now. I will open 80/443 in later phases.

## 4. SSH hardening

```bash
sudo sshd -T | grep -E 'passwordauthentication|permitrootlogin|pubkeyauthentication'
```

```
permitrootlogin no
pubkeyauthentication yes
passwordauthentication no
```

| Setting | Value | Why |
|---------|-------|-----|
| `PasswordAuthentication` | no | Removes password brute-forcing as an attack |
| `PubkeyAuthentication` | yes | Login requires my private key |
| `PermitRootLogin` | no | Root is never directly exposed; I use a normal user plus `sudo` |

**Lesson learned:** my first attempt at the check was `sudo sshd -T | grep -E` with no pattern, which fails with a grep usage error. `grep -E` needs a pattern to match.

## 5. Automatic security updates

```bash
systemctl status unattended-upgrades
```

```
unattended-upgrades.service - Unattended Upgrades Shutdown
     Loaded: loaded (...; enabled; preset: enabled)
     Active: active (running)
```

**Why:** the server is only powered on during sessions, so I can't rely on remembering to patch it. Unattended upgrades applies security updates automatically.

## 6. Virtualization support

```bash
kvm-ok
```

```
INFO: /dev/kvm exists
KVM acceleration can be used
```

**Why:** later phases need VMs (for example, the Ansible rebuild test and Zabbix). KVM acceleration makes them practical on this hardware.

## 7. Power use

The server is powered on only during sessions (`sudo poweroff` when done). To reduce electricity use while it is on:

- Installed **TLP** for power management.
- Set the CPU governor to `ondemand` in `/etc/tlp.d/10-cpu.conf`, so the CPU only clocks up under load.
- The system drive is an SSD, so no HDD spin-down tuning is needed.

## Result

The server is reachable only over SSH with a key, exposes one port, patches itself, and can run VMs. This is the foundation for Phase 2 (Nginx).