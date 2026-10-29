#!/bin/sh
for v in step1 step2; do
  echo "== $v"
  /work/$v/bin/joinery-relay --port 8796 --metrics-port 9196 > /tmp/$v.log 2>&1 &
  relay=$!
  sleep 0.5
  /work/load --port 8796 --rooms 50 --guests 7 --rate 5 --presence 30 --slow 1 --seconds 20 2>&1 | tail -4
  wget -qO- http://127.0.0.1:9196/metrics | grep -E "^joinery_relay_(pointers_replaced|lagging|dropped)"
  echo "cpu: $(cat /proc/$relay/stat | awk '{print ($14+$15)/100 " s"}')  rss: $(grep VmRSS /proc/$relay/status)"
  kill $relay; sleep 1
done
