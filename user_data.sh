#!/bin/bash
env=$1
app=$2
role=$3
[ -z "$3" ] && echo "Error" && exit
echo "Initializing PostgreSQL Database Server in ${env} for ${app} as ${role}"

###
# Need to pass in prometheus postgres password
# Need to set node_labels
# Need to set read-ahead for st1 volumes to 2048 (blockdev --setra 2048 /dev/nvmeXn1)
PROM_PASS="dark3"

packages='aptitude golang-go'
zfs_packages='zfs-zed zfsutils-linux'
pg_packages='postgresql-11-citus-8.2 postgresql-11-partman postgresql-11-repack pgadmin4 postgresql-contrib-11 postgresql-server-dev-11 postgresql-plperl-11 postgresql-11-pgtap postgresql-11-hypopg pgbackrest'
prom_packages='prometheus-node-exporter'
prod_networks='172.20.128.0/22 172.20.132.0/22 172.20.136.0/22 172.20.160.0/19 172.20.192.0/19 172.20.224.0/19 172.20.131.46/32 172.20.138.164/32'
test_networks='172.20.0.0/22 172.20.4.0/22 172.20.8.0/22 172.20.32.0/19 172.20.64.0/19 172.20.96.0/19 172.20.10.189/32'
arc_mem_min_pct=15
arc_mem_max_pct=25
arc_sb_pct=50
version='11'

# Install packages

curl https://install.citusdata.com/community/deb.sh | bash
apt-get update && apt-get -y install ${packages} ${zfs_packages} ${pg_packages} ${prom_packages}

# Configure ZFS

root_part=$(df -h | grep nvme | tr '/' ' ' | awk '{ print $2 }')
root_dev=${root_part%p1}

for dev in $(ls /dev/nvme*n1 | grep -v $root_dev); do
   sgdisk -Zg -n1:0:4095 -t1:EF02 -c1:GRUB -n2:0:0 -t2:BF01 -c2:ZFS $dev
done
partprobe
sleep 5
(( i = 1 ))
for dev in $(ls /dev/nvme*n1 | grep -v $root_dev | cut -c6-); do
   part[$i]=$(ls -al /dev/disk/by-partuuid | grep ${dev}p2 | awk '{ print $9 }') && (( i++ ))
done

echo ${part[@]}

mem_bytes=$(free -b | grep Mem | awk '{ print $2 }')
(( arc_mem_min_bytes = mem_bytes * arc_mem_min_pct / 100 ))
(( arc_mem_max_bytes = mem_bytes * arc_mem_max_pct / 100 ))
(( sb_bytes = 4 * 1024 * 1024 * 1024 ))
(( arc_sb_bytes = sb_bytes * arc_sb_pct / 100 ))
(( arc_min = arc_mem_min_bytes + arc_sb_bytes ))
(( arc_max = arc_mem_max_bytes + arc_sb_bytes ))

cat <<EOF > /etc/modprobe.d/zfs.conf
options zfs zfs_autoimport_disable=0
options zfs zfs_prefetch_disable=1
options zfs zfs_txg_timeout=1
options zfs zfs_arc_min=$arc_min
options zfs zfs_arc_max=$arc_max
EOF

echo 'zfs mount -a' > /etc/rc.local
sleep 5
mkdir /pg

zpool create -o ashift=12 -O atime=off -O compression=lz4 -O dedup=off -O exec=off -O logbias=throughput -O primarycache=metadata -O recordsize=128K -O reservation=1G -O relatime=on -O sync=standard -m none rpool mirror /dev/disk/by-partuuid/${part[1]} /dev/disk/by-partuuid/${part[6]} mirror /dev/disk/by-partuuid/${part[2]} /dev/disk/by-partuuid/${part[7]} mirror /dev/disk/by-partuuid/${part[3]} /dev/disk/by-partuuid/${part[8]} mirror /dev/disk/by-partuuid/${part[4]} /dev/disk/by-partuuid/${part[9]} mirror /dev/disk/by-partuuid/${part[5]} /dev/disk/by-partuuid/${part[10]}
#zpool create -o ashift=12 -O atime=off -O compression=lz4 -O dedup=off -O exec=off -O logbias=throughput -O primarycache=metadata -O recordsize=128K -O reservation=1G -O relatime=on -O sync=standard -m none rpool /dev/disk/by-partuuid/${part[1]} /dev/disk/by-partuuid/${part[2]} /dev/disk/by-partuuid/${part[3]} /dev/disk/by-partuuid/${part[4]} /dev/disk/by-partuuid/${part[5]}
zpool status
zpool_size=0
for msize in $(zdb | grep asize | awk '{ print $2 }'); do (( zpool_size += msize )); done
(( zpool_size = zpool_size / 1024 / 1024 / 1024 ))
(( zpool_max_size = zpool_size * 80 / 100 ))
(( zfs_slot_size = zpool_max_size / 20 ))
(( zfs_quota_db = zfs_slot_size * 10 ))
(( zfs_quota_logs = zfs_slot_size * 1 ))
(( zfs_quota_bkup = zfs_slot_size * 7 ))
zfs create -o mountpoint=/pg/db -o quota=${zfs_quota_db}G rpool/db
zfs create -o mountpoint=/pg/logs -o quota=${zfs_quota_logs}G rpool/logs
zfs create -o mountpoint=/pg/bkup -o quota=${zfs_quota_bkup}G rpool/bkup
zfs list
chown -R postgres. /pg
zdb
sleep 120

# Initialize database

cluster=${app}
pg_lsclusters | grep -q main && pg_dropcluster ${version} main --stop
pg_createcluster ${version} ${cluster} -d /pg/db/${cluster} -- --no-locale -E=UTF8 -n -N
systemctl daemon-reload
mkdir /pg/logs/${cluster} && chown -R postgres. /pg/logs/${cluster} && mv /pg/db/${cluster}/pg_wal /pg/logs/${cluster} && ln -s /pg/logs/${cluster}/pg_wal /pg/db/${cluster}
networks=""
if [[ "${env}" = "prod" ]]; then
   networks=$prod_networks
else
   networks=$test_networks
fi
hba=/etc/postgresql/${version}/${cluster}/pg_hba.conf
pg_conftool ${version} ${cluster} set shared_preload_libraries citus
pg_conftool ${version} ${cluster} set listen_addresses '*'
pg_conftool ${version} ${cluster} set full_page_writes off
pg_conftool ${version} ${cluster} set work_mem 12MB
pg_conftool ${version} ${cluster} set shared_buffers 4GB
pg_conftool ${version} ${cluster} set random_page_cost 2
pg_conftool ${version} ${cluster} set maintenance_work_mem 1GB
pg_conftool ${version} ${cluster} set effective_cache_size 40GB
pg_conftool ${version} ${cluster} set pg_partman_bgw.dbname dark3
pg_conftool ${version} ${cluster} set pg_partman_bgw.analyze off

mv ${hba} ${hba}.bak
cat <<EOF > ${hba}
# DO NOT DISABLE!
# If you change this first entry you will need to make sure that the
# database superuser can access the database using some other method.
# Noninteractive access to all databases is required during automatic
# maintenance (custom daily cronjobs, replication, and similar tasks).
#
# Database administrative login by Unix domain socket
local   all             postgres                                peer

# TYPE  DATABASE        USER            ADDRESS                 METHOD
# local is for Unix domain socket connections only
local   all             all                                     peer
# IPv4 local connections:
host    all             all             127.0.0.1/32            trust
# IPv6 local connections:
host    all             all             ::1/128                 trust
# Allow replication connections from localhost, by a user with the
# replication privilege.
local   replication     all                                     peer
host    replication     all             127.0.0.1/32            md5
host    replication     all             ::1/128                 md5
EOF
echo '# Local network connections:' >> ${hba}
for net in ${networks}; do echo $'host\tall\t\tall\t\t'${net}$'\t\ttrust' >> ${hba}; done
chown postgres. ${hba} && chmod 640 ${hba}
systemctl enable postgresql && systemctl restart postgresql

# Configure prometheus exporters
cat <<EOF > /etc/default/prometheus-node-exporter
# Set the command-line arguments to pass to the server.
# Due to shell scaping, to pass backslashes for regexes, you need to double
# them (\\d for \d). If running under systemd, you need to double them again
# (\\\\d to mean \d), and escape newlines too.
ARGS="--collector.diskstats.ignored-devices=^(ram|loop|fd|(h|s|v|xv)d[a-z]|nvme\\d+n\\d+p)\\d+$ \\
      --collector.filesystem.ignored-mount-points=^/(sys|proc|dev|run)($|/) \\
      --collector.netdev.ignored-devices=^lo$ \\
      --collector.textfile.directory=/var/lib/prometheus/node-exporter"

# Prometheus-node-exporter supports the following options:
#
#  --collector.diskstats.ignored-devices="^(ram|loop|fd|(h|s|v|xv)d[a-z]|nvme\\d+n\\d+p)\\d+$"
#                            Regexp of devices to ignore for diskstats.
#  --collector.filesystem.ignored-mount-points="^/(sys|proc|dev)($|/)"
#                            Regexp of mount points to ignore for filesystem
#                            collector.
#  --collector.filesystem.ignored-fs-types="^(sys|proc|auto)fs$"
#                            Regexp of filesystem types to ignore for
#                            filesystem collector.
#  --collector.megacli.command="megacli"
#                            Command to run megacli.
#  --collector.netdev.ignored-devices="^$"
#                            Regexp of net devices to ignore for netdev
#                            collector.
#  --collector.ntp.server="127.0.0.1"
#                            NTP server to use for ntp collector
#  --collector.ntp.protocol-version=4
#                            NTP protocol version
#  --collector.ntp.server-is-local
#                            Certify that collector.ntp.server address is the
#                            same local host as this collector.
#  --collector.ntp.ip-ttl=1  IP TTL to use while sending NTP query
#  --collector.ntp.max-distance=3.46608s
#                            Max accumulated distance to the root
#  --collector.ntp.local-offset-tolerance=1ms
#                            Offset between local clock and local ntpd time
#                            to tolerate
#  --path.procfs="/proc"     procfs mountpoint.
#  --path.sysfs="/sys"       sysfs mountpoint.
#  --collector.qdisc.fixtures=""
#                            test fixtures to use for qdisc collector
#                            end-to-end testing
#  --collector.runit.servicedir="/etc/service"
#                            Path to runit service directory.
#  --collector.supervisord.url="http://localhost:9001/RPC2"
#                            XML RPC endpoint.
#  --collector.systemd.unit-whitelist=".+"
#                            Regexp of systemd units to whitelist. Units must
#                            both match whitelist and not match blacklist to
#                            be included.
#  --collector.systemd.unit-blacklist=".+\\.scope"
#                            Regexp of systemd units to blacklist. Units must
#                            both match whitelist and not match blacklist to
#                            be included.
#  --collector.systemd.private
#                            Establish a private, direct connection to
#                            systemd without dbus.
#  --collector.textfile.directory=""
#                            Directory to read text files with metrics from.
#  --collector.wifi.fixtures=""
#                            test fixtures to use for wifi collector metrics
#  --collector.arp           Enable the arp collector (default: enabled).
#  --collector.bcache        Enable the bcache collector (default: enabled).
#  --collector.bonding       Enable the bonding collector (default:
#                            disabled).
#  --collector.buddyinfo     Enable the buddyinfo collector (default:
#                            disabled).
#  --collector.conntrack     Enable the conntrack collector (default:
#                            enabled).
#  --collector.cpu           Enable the cpu collector (default: enabled).
#  --collector.diskstats     Enable the diskstats collector (default:
#                            enabled).
#  --collector.drbd          Enable the drbd collector (default: disabled).
#  --collector.edac          Enable the edac collector (default: enabled).
#  --collector.entropy       Enable the entropy collector (default: enabled).
#  --collector.filefd        Enable the filefd collector (default: enabled).
#  --collector.filesystem    Enable the filesystem collector (default:
#                            enabled).
#  --collector.gmond         Enable the gmond collector (default: disabled).
#  --collector.hwmon         Enable the hwmon collector (default: enabled).
#  --collector.infiniband    Enable the infiniband collector (default:
#                            enabled).
#  --collector.interrupts    Enable the interrupts collector (default:
#                            disabled).
#  --collector.ipvs          Enable the ipvs collector (default: enabled).
#  --collector.ksmd          Enable the ksmd collector (default: disabled).
#  --collector.loadavg       Enable the loadavg collector (default: enabled).
#  --collector.logind        Enable the logind collector (default: disabled).
#  --collector.mdadm         Enable the mdadm collector (default: enabled).
#  --collector.megacli       Enable the megacli collector (default:
#                            disabled).
#  --collector.meminfo       Enable the meminfo collector (default: enabled).
#  --collector.meminfo_numa  Enable the meminfo_numa collector (default:
#                            disabled).
#  --collector.mountstats    Enable the mountstats collector (default:
#                            disabled).
#  --collector.netdev        Enable the netdev collector (default: enabled).
#  --collector.netstat       Enable the netstat collector (default: enabled).
#  --collector.nfs           Enable the nfs collector (default: disabled).
#  --collector.ntp           Enable the ntp collector (default: disabled).
#  --collector.qdisc         Enable the qdisc collector (default: disabled).
#  --collector.runit         Enable the runit collector (default: disabled).
#  --collector.sockstat      Enable the sockstat collector (default:
#                            enabled).
#  --collector.stat          Enable the stat collector (default: enabled).
#  --collector.supervisord   Enable the supervisord collector (default:
#                            disabled).
#  --collector.systemd       Enable the systemd collector (default:
#                            disabled).
#  --collector.tcpstat       Enable the tcpstat collector (default:
#                            disabled).
#  --collector.textfile      Enable the textfile collector (default:
#                            enabled).
#  --collector.time          Enable the time collector (default: enabled).
#  --collector.uname         Enable the uname collector (default: enabled).
#  --collector.vmstat        Enable the vmstat collector (default: enabled).
#  --collector.wifi          Enable the wifi collector (default: enabled).
#  --collector.xfs           Enable the xfs collector (default: enabled).
#  --collector.zfs           Enable the zfs collector (default: enabled).
#  --collector.timex         Enable the timex collector (default: enabled).
#  --web.listen-address=":9100"
#                            Address on which to expose metrics and web
#                            interface.
#  --web.telemetry-path="/metrics"
#                            Path under which to expose metrics.
#  --log.level="info"        Only log messages with the given severity or
#                            above. Valid levels: [debug, info, warn, error,
#                            fatal]
#  --log.format="logger:stderr"
#                            Set the log target and format. Example:
#                            "logger:syslog?appname=bob&local=7" or
#                            "logger:stdout?json=true"
#  --version                 Show application version.
EOF
#tf_dir="/var/lib/prometheus/node-exporter"
#echo "app{app=\"${app}\"} 1" > ${tf_dir}/app.pro_
#echo "role{role=\"${role}\"} 1" > ${tf_dir}/role.pro_
#chown prometheus. ${tf_dir}/*.pro_
#for file in ${tf_dir}/*.pro_; do mv ${file} ${file%_}m; done

cat <<EOF > /var/lib/postgresql/prometheus-postgres-exporter.sql
CREATE USER prometheus WITH PASSWORD '${PROM_PASS}';
ALTER USER prometheus SET SEARCH_PATH TO postgres_exporter,pg_catalog;

GRANT prometheus TO postgres;
CREATE SCHEMA IF NOT EXISTS postgres_exporter;
GRANT USAGE ON SCHEMA postgres_exporter TO prometheus;


CREATE FUNCTION get_pg_stat_activity() RETURNS SETOF pg_stat_activity AS
\$\$ SELECT * FROM pg_catalog.pg_stat_activity; \$\$
LANGUAGE sql
VOLATILE
SECURITY DEFINER;

CREATE OR REPLACE VIEW postgres_exporter.pg_stat_activity
AS
  SELECT * from get_pg_stat_activity();

GRANT SELECT ON postgres_exporter.pg_stat_activity TO prometheus;

CREATE OR REPLACE FUNCTION get_pg_stat_replication() RETURNS SETOF pg_stat_replication AS
\$\$ SELECT * FROM pg_catalog.pg_stat_replication; \$\$
LANGUAGE sql
VOLATILE
SECURITY DEFINER;

CREATE OR REPLACE VIEW postgres_exporter.pg_stat_replication
AS
  SELECT * FROM get_pg_stat_replication();

GRANT SELECT ON postgres_exporter.pg_stat_replication TO prometheus;
EOF
sudo -i -u postgres psql -a -f /var/lib/postgresql/prometheus-postgres-exporter.sql
go_dir="/root/go"
[ -d "${go_dir}" ] ||  mkdir ${go_dir}
export GOPATH=${go_dir}
cd ${go_dir}
go get github.com/wrouesnel/postgres_exporter
cd src/github.com/wrouesnel/postgres_exporter
go run mage.go binary
cp postgres_exporter /usr/bin/prometheus-postgres-exporter
cat <<EOF > /etc/default/prometheus-postgres-exporter
# Set the command-line arguments to pass to the server.
# Due to shell scaping, to pass backslashes for regexes, you need to double
# them (\\d for \d). If running under systemd, you need to double them again
# (\\\\d to mean \d), and escape newlines too.
DATA_SOURCE_NAME="postgresql://prometheus:${PROM_PASS}@localhost:5432/postgres"
ARGS=""
# Prometheus-postgres-exporter supports the following options:
#  --audo-discover-databases
#                            Database DSNs are dynamically discovered
#                            using "SELECT datname (NOT disname) FROM
#                            pg_database".
#  --constantLabels=""
#                            Labels to set in all metrics.  Provide
#                            a list of "label=value" pairs, separated
#                            by commas.
#  --disable-default-metrics
#                            Use only metrics supplied from "queries.yaml"
#                            via --extend.query_path.
#  --disable-settings-metrics
#                            Disable scraping of pg_settings.
#  --dumpmaps
#                            Print the internal representation of the
#                            metric maps and exit.  Used to debug
#                            custom queries.
#  --extend.query-path=""
#                            Path to a YAML file containing custom queries
#                            to run.  Review "queries.yaml" for examples
#                            of the format.
#  --log.level="info"        Only log messages with the given severity or
#                            above. Valid levels: [debug, info, warn, error,
#                            fatal]
#  --log.format="logger:stderr"
#                            Set the log target and format. Example:
#                            "logger:syslog?appname=bob&local=7" or
#                            "logger:stdout?json=true"
#  --web.listen-address=":9187"
#                            Address on which to expose metrics and web
#                            interface.
#  --web.telemetry-path="/metrics"
#                            Path under which to expose metrics.
#  --version                 Show application version.
EOF
cat <<EOF > /etc/systemd/system/prometheus-postgres-exporter.service
[Unit]
Description=Prometheus exporter for PostgreSQL metrics
Documentation=https://github.com/wrouesnel/postgres_exporter

[Service]
Restart=always
User=prometheus
EnvironmentFile=/etc/default/prometheus-postgres-exporter
ExecStart=/usr/bin/prometheus-postgres-exporter \$ARGS
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=20s
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF
go_dir="/root/go"
[ -d "${go_dir}" ] ||  mkdir ${go_dir}
export GOPATH=${go_dir}
cd ${go_dir}
go get github.com/pdf/zfs_exporter
cd src/github.com/pdf/zfs_exporter
make build
cp zfs_exporter /usr/bin/prometheus-zfs-exporter
cat <<EOF > /etc/default/prometheus-zfs-exporter
# Set the command-line arguments to pass to the server.
# Due to shell scaping, to pass backslashes for regexes, you need to double
# them (\\d for \d). If running under systemd, you need to double them again
# (\\\\d to mean \d), and escape newlines too.
ARGS="--collector.dataset-snapshot"
# Prometheus-postgres-exporter supports the following options:
#  --collector.dataset-filesystem
#                            Enable the dataset-filesystem collector
#                            (default: enabled).
#  --collector.dataset-snapshot
#                            Enable the dataset-snapshot collector
#                            (default: disabled).
#  --collector.dataset-volume
#                            Enable the dataset-volume collector
#                            (default: enabled).
#  --collector.pool
#                            Enable the pool collector (default: enabled).
#  --deadline=8s
#                            Meximum duration that a collection should run
#                            before returning cached data. Should be set to
#                            a value shorter than your scrape timeout
#                            duration.  The current collection run will
#                            continue and update the cache when complete.
#  --pool=
#                            Name of the pool(s) to collect. Repeat for
#                            multiple pools.  (default: all pools).
#  --log.level="info"        Only log messages with the given severity or
#                            above. Valid levels: [debug, info, warn, error,
#                            fatal]
#  --log.format="logger:stderr"
#                            Set the log target and format. Example:
#                            "logger:syslog?appname=bob&local=7" or
#                            "logger:stdout?json=true"
#  --web.listen-address=":9134"
#                            Address on which to expose metrics and web
#                            interface.
#  --web.telemetry-path="/metrics"
#                            Path under which to expose metrics.
#  --version                 Show application version.
EOF
cat <<EOF > /etc/systemd/system/prometheus-zfs-exporter.service
[Unit]
Description=Prometheus exporter for ZFS metrics
Documentation=https://github.com/pdf/zfs_exporter

[Service]
Restart=always
User=prometheus
EnvironmentFile=/etc/default/prometheus-zfs-exporter
ExecStart=/usr/bin/prometheus-zfs-exporter \$ARGS
ExecReload=/bin/kill -HUP \$MAINPID
TimeoutStopSec=20s
SendSIGKILL=no

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart prometheus-node-exporter prometheus-postgres-exporter prometheus-zfs-exporter
systemctl enable prometheus-node-exporter prometheus-postgres-exporter prometheus-zfs-exporter
