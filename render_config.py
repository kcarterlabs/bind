import yaml
from datetime import datetime

def render_zone(config_file, output_file, zone_name):
    with open(config_file, 'r') as f:
        records = yaml.safe_load(f)

    with open(output_file, 'w') as f:
        f.write(f"""\$TTL {records.get('ttl', 3600)}
@   IN  SOA ns1.{zone_name}. admin.{zone_name}. (
        {int(datetime.now().timestamp())} ; Serial
        3600    ; Refresh
        1800    ; Retry
        604800  ; Expire
        86400 ) ; Minimum
@   IN  NS  ns1.{zone_name}.
ns1 IN  A   {records.get('ns_ip', '127.0.0.1')}
""")
        for record in records.get("records", []):
            name = record["name"]
            rtype = record["type"]
            value = record["value"]
            f.write(f"{name} IN {rtype} {value}\n")
