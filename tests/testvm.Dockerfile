# A stand-in for a freshly cloned Ubuntu 24.04 VM, for scripts/test-playbook.sh:
# systemd as PID 1, so the role installs and starts Docker and turns off
# systemd-resolved's stub listener as it would on the real thing. Roughly
# what the cloud image ships: python3-apt, cron and systemd-resolved (its stub
# listening on 127.0.0.53:53), no Docker. Same base as ~/Code/traefik's.
#
# The base image's policy-rc.d stops apt from starting services; a VM has
# none, so it goes. The package lists stay, as on a VM: `apt` under --check
# can't refresh them. Run it --privileged with volumes on /var/lib/docker and
# /var/lib/containerd: overlay can't sit on the container's own overlay.
FROM ubuntu:24.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      systemd systemd-sysv systemd-resolved dbus cron python3 python3-apt sudo iproute2 \
      curl ca-certificates gnupg \
 && apt-get clean \
 && rm -f /usr/sbin/policy-rc.d \
 && systemctl mask getty.target console-getty.service systemd-logind.service
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
