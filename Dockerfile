FROM ubuntu:22.04

RUN apt-get update && \
    apt-get install -y bind9 bind9utils bind9-dnsutils python3 python3-pip inotify-tools && \
    pip3 install pyyaml && \
    mkdir -p /etc/bind/zones && \
    rm -rf /var/lib/apt/lists/*

COPY named.conf.options /etc/bind/named.conf.options
COPY named.conf.local /etc/bind/named.conf.local
COPY records.yaml /etc/bind/records.yaml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY zone_converter.py /usr/local/bin/zone_converter.py
COPY bind-reload.sh /usr/local/bin/bind-reload

RUN chmod +x /usr/local/bin/zone_converter.py

RUN chmod 640 /etc/bind/rndc.key && chown root:bind /etc/bind/rndc.key

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/zone_converter.py /usr/local/bin/bind-reload

EXPOSE 53/udp 53/tcp

# Answers for its own zone's SOA.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD dig +short +time=2 +tries=1 @127.0.0.1 kcarterlabs.tech SOA | grep -q . || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
