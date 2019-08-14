#!/bin/bash

arg="$1"
base=${arg%.db*}
len=$(echo $base | wc -c)
(( split = $len - 2 ))
(( i = $split + 1 ))
role=$(echo $base | cut -c-$split)
ind=$(echo $base | cut -c $i)
name="saas-db-${role}-${ind}"

ssh $1 -t "echo \"node_labels{role=\\\"${role}\\\",app=\\\"saas\\\",hostname=\\\"${name}\\\",fqdn=\\\"${name}.darkcubed.calops\\\",nodename=\\\"\$(hostname)\\\",instance=\\\"\$(hostname | cut -c4-)\\\",cluster=\\\"saas\\\"} 1\" | sudo tee -a /var/lib/prometheus/node-exporter/node_labels.prom && sudo chown prometheus. /var/lib/prometheus/node-exporter/node_labels.prom"
#node_labels{role="worker",app="saas",hostname="saas-db-worker-7",fqdn="saas-db-worker-7.darkcubed.test",nodename="ip-172-20-124-137",instance="172-20-124-137",cluster="test3"} 1
