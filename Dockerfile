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

RUN chmod +x /usr/local/bin/zone_converter.py

RUN chmod 640 /etc/bind/rndc.key && chown root:bind /etc/bind/rndc.key

RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/zone_converter.py

EXPOSE 53/udp 53/tcp

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
