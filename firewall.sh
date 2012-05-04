#!/bin/bash

test "$1" == "debug" && set -x
test "$1" == "show"  && iptables() { echo iptables "$@"; } && ip() { echo ip "$@"; } 

source firewall.conf

echo "Generating routing rules..."
ip rule flush 2>/dev/null
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
  ip route flush table enlace$i 2>/dev/null
  ip route add default via ${inet_gw[$i]} dev ${inet_iface[$i]} proto static table enlace$i
  ip rule add from ${inet_ip[$i]} prio 10$i table enlace$i
  ip rule add fwmark 0x$i prio 20$i table enlace$i
  multipath="$multipath nexthop via ${inet_gw[$i]} dev ${inet_iface[$i]} weight ${inet_weight[$i]}"
  echo "done"
done
echo -n " * Setting default route: "
ip route del default table main 2>/dev/null
if [ -n "$inet_default" ]; then
  ip ro add default proto static via ${inet_gw[$inet_default]}
else
  ip route add default proto static $multipath 
fi
ip route flush cache
echo "done"

echo "Setting firewall rules..."
# Activamos el IP forwarding
echo -n " * Activating IP Forwarding support: "
echo "1" > /proc/sys/net/ipv4/ip_forward
echo "done"

echo -n " * Deleting firewall rules:"
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
echo "done"

echo -n " * Generating packet marking rules: "
iptables -t mangle -A PREROUTING -j CONNMARK --restore-mark
iptables -t mangle -N ENLACES
iptables -t mangle -A FORWARD -m mark --mark 0x0 -j ENLACES
iptables -t mangle -A FORWARD -j MARK --set-mark 0x0

for ((i=1;i<=${#lan_iface[@]};i++)); do
  iptables -t mangle -A ENLACES -o ${lan_iface[$i]} -j RETURN
done

for ((i=1;i<=${#inet_gw[@]};i++)); do
  iptables -t mangle -A ENLACES -o ${inet_iface[$i]} -j MARK --set-mark 0x$i
  iptables -t mangle -A ENLACES -i ${inet_iface[$i]} -j MARK --set-mark 0x$i
done

iptables -t mangle -A ENLACES -j CONNMARK --save-mark
echo "done"

echo -n " * Setting Firewall: "
for ((i=1;i<=${#inet_gw[@]};i++)); do
  for port in ${inet_tcp_ports[$i]}; do
    iptables -A INPUT -i ${inet_iface[$i]} -p tcp --dport $port -j ACCEPT
  done
  for port in ${inet_udp_ports[$i]}; do
    iptables -A INPUT -i ${inet_iface[$i]} -p tcp --dport $port -j ACCEPT
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
    for i in ${inet_redirections[$i]}; do
      extport=$(echo $i | awk -F ':' '{ print $1 }')
      intip=$(echo $i | awk -F ':' '{ print $2 }')
      intport=$(echo $i | awk -F ':' '{ print $3 }')
      proto=$(echo $i | awk -F ':' '{ print $4 }')

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
