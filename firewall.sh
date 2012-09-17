#!/bin/bash

config="/etc/firewall.conf"

test "$2" == "debug" && set -x
test "$2" == "show"  && iptables() { echo iptables "$@"; } && ip() { echo ip "$@"; } && tc() { echo tc "$@"; }  

[ ! -f $config ] && echo "ERROR: File $config doesn't exist" && exit 1
source $config


function stop_fw {
  echo "Stopping firewall..."
  echo -n " * Deleting routes and routing rules: "
  ip rule flush
  ip rule del from all table main 2>/dev/null
  ip rule add from all prio 1 table main
  ip rule add from all prio 32767 table default
  for ((i=1;i<=${#inet_gw[@]};i++)); do
    ip route flush table enlace$i 2>/dev/null
  done
  echo "done"

  echo -n " * Deleting firewall rules: "
  iptables -F
  iptables -X
  iptables -t nat -F
  iptables -t nat -X
  iptables -t mangle -F
  iptables -t mangle -X
  echo "done"
}

function start_fw {
  echo "Starting firewall..."
  echo -n " * Activating IP Forwarding support: "
  echo 1 > /proc/sys/net/ipv4/ip_forward
  echo "done"

  echo -n " * Deactivating IP spoofing: "
  for i in $(ls /proc/sys/net/ipv4/conf/); do
    echo 0 > /proc/sys/net/ipv4/conf/$i/rp_filter
  done
  echo "done"

  echo -n " * Setting Firewall: "
  for ((i=1;i<=${#inet_gw[@]};i++)); do
    for port in ${inet_tcp_ports[$i]}; do
      iptables -A INPUT -i ${inet_iface[$i]} -p tcp --dport $port -j ACCEPT
    done
    for port in ${inet_udp_ports[$i]}; do
      iptables -A INPUT -i ${inet_iface[$i]} -p udp --dport $port -j ACCEPT
    done
  done
  iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
  # Acepto VPN y LAN
  for ((i=1;i<=${#lan_iface[@]};i++)); do
    iptables -A INPUT -i ${lan_iface[$i]} -j ACCEPT
    iptables -A FORWARD -i ${lan_iface[$i]} -j ACCEPT
  done
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A INPUT -i tun+ -j ACCEPT
  # Acepto ICMP
  iptables -A INPUT -p icmp -j ACCEPT
  # No permito conexiones a los demas puertos desde inet
  iptables -A INPUT -j REJECT
  echo "done"

  echo -n " * Activating Port Forwarding: "
  for ((i=1;i<=${#inet_gw[@]};i++)); do
    if [[ -n "${inet_redirections[$i]}" ]]; then
      for n in ${inet_redirections[$i]}; do
        extport=$(echo $n | awk -F ':' '{ print $1 }')
        intip=$(echo $n | awk -F ':' '{ print $2 }')
        intport=$(echo $n | awk -F ':' '{ print $3 }')
        proto=$(echo $n | awk -F ':' '{ print $4 }')

        iptables -t nat -A PREROUTING -p $proto -i ${inet_iface[$i]} --dport $extport -j DNAT --to $intip:$intport
      done
    fi
  done
  echo "done"

  echo -n " * Activating NAT: "
  for ((i=1;i<=${#inet_gw[@]};i++)); do
    iptables -t nat -A POSTROUTING -o ${inet_iface[$i]} -j MASQUERADE
  done
  iptables -t mangle -A FORWARD -m tcp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  echo "done"

  echo -n " * Activating Transparent Proxy: "
  for ((i=1;i<=${#lan_iface[@]};i++)); do
    [ -n "${lan_proxy[$i]}" ] && iptables -t nat -A PREROUTING -i ${lan_iface[$i]} ! -d ${lan_net[$i]} -p tcp -m tcp --dport 80 -j DNAT --to-destination ${lan_proxy[$i]}
  done
  echo "done"

  echo -n " * Generating packet marking rules: "
  iptables -t mangle -N FORCE_PROVIDER
  iptables -t mangle -A PREROUTING -j FORCE_PROVIDER
  iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
  iptables -t mangle -A PREROUTING -m mark ! --mark 0 -j ACCEPT
  iptables -t mangle -A OUTPUT -j FORCE_PROVIDER
  iptables -t mangle -A OUTPUT -j CONNMARK --restore-mark

  for ((i=1;i<=${#inet_gw[@]};i++)); do
    iptables -t mangle -A PREROUTING -i ${inet_iface[$i]} -j MARK --set-mark 0x$i
    iptables -t mangle -A PREROUTING -i ${inet_iface[$i]} -j CONNMARK --save-mark
    for f in ${inet_force_dest[$i]}; do
      iptables -t mangle -A FORCE_PROVIDER -d $f -j MARK --set-mark 0x$i
      iptables -t mangle -A FORCE_PROVIDER -d $f -j CONNMARK --save-mark
    done
  done
  echo "done"

  echo "Generating routing rules..."
  ip rule del from all table main 2>/dev/null
  ip rule add from all prio 1 table main
  ip rule add from all prio 32767 table default
  for ((i=1;i<=${#inet_gw[@]};i++)); do
    if [ -z "$(cat /etc/iproute2/rt_tables | grep enlace$i)" ]; then
      echo -n " * Adding table enlace$i to /etc/iproute2/rt_tables: "
      echo -e "10$i\tenlace$i" >> /etc/iproute2/rt_tables
      echo "done"
    fi

    echo -n " * Setting link $i ${inet_name[$i]}: "
    if [[ "${inet_iface[$i]%%[0-9]*}" == "ppp" ]]; then
      ppp_ip=$(LANG=us_US ifconfig ${inet_iface[$i]} | grep "inet addr:" | awk '{print $2}' | awk -F ":" '{print $2}')
      ip route add default dev ${inet_iface[$i]} scope link table enlace$i
      ip rule add from $ppp_ip prio 100 table enlace$i
      multipath="$multipath nexthop dev ${inet_iface[$i]} weight ${inet_weight[$i]}"
    else
      ip route add default via ${inet_gw[$i]} dev ${inet_iface[$i]} proto static table enlace$i
      ip rule add from ${inet_ip[$i]} prio 100 table enlace$i
      multipath="$multipath nexthop via ${inet_gw[$i]} dev ${inet_iface[$i]} weight ${inet_weight[$i]}"
    fi
    ip rule add fwmark 0x$i prio 200 table enlace$i
    echo "done"
  done
  echo -n " * Setting default route: "
  ip route del default table main 2>/dev/null
  ip route del default table default 2>/dev/null
  if [ -n "$inet_default" ]; then
    if [[ "${inet_iface[$inet_default]%%[0-9]*}" == "ppp" ]]; then
      ip ro add default dev ${inet_iface[$i]} scope link table default
    else
      ip ro add default proto static via ${inet_gw[$inet_default]} table default
    fi
  else
    ip route add table default default proto static $multipath
  fi
  ip route flush cache
  echo "done"
}

case "$1" in
  stop)
    stop_fw
    ;;

  start|restart)
    stop_fw
    start_fw
    ;;

  *)
    echo "Uso: $0 [start | stop | restart] [debug | show]"
    exit 1
esac
