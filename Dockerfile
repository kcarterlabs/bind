FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \
    apt-get install -y bind9 bind9utils dnsutils python3-pip inotify-tools && \
    pip install flask pyyaml && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
COPY render_config.py /render_config.py
COPY flask_server.py /flask_server.py

RUN chmod +x /entrypoint.sh

EXPOSE 53/udp 53/tcp 5000

VOLUME ["/data"]

ENTRYPOINT ["/entrypoint.sh"]
