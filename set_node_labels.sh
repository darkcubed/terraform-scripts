#!/bin/bash

ssh worker1.db3 -t "echo \"node_labels{role=\\\"worker\\\",app=\\\"saas\\\",hostname=\\\"saas-db-worker-7\\\",fqdn=\\\"saas-db-worker-7.darkcubed.test\\\",nodename=\\\"\$(hostname)\\\",instance=\\\"\$(hostname | cut -c4-)\\\",cluster=\\\"test3\\\"} 1\" | sudo tee -a /var/lib/prometheus/node-exporter/node_labels.prom && sudo chown prometheus. /var/lib/prometheus/node-exporter/node_labels.prom"
node_labels{role="worker",app="saas",hostname="saas-db-worker-7",fqdn="saas-db-worker-7.darkcubed.test",nodename="ip-172-20-124-137",instance="172-20-124-137",cluster="test3"} 1
