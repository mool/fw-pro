#!/bin/bash

config="/etc/firewall.conf"

test "$1" == "debug" && set -x

[ ! -f $config ] && echo "ERROR: File $config doesn't exist" && exit 1
source $config

root_dnservers="B C D E F I J K L M"

pong=0
multipath_total=0

if [ -n "$inet_default" ]; then
  for letter in $root_dnservers; do
    if(ping -n -c1 -W2 $letter.root-servers.net -I ${inet_ip[$inet_default]} &>/dev/null);then
      pong=1
      multipath=" nexthop via ${inet_gw[$inet_default]}  dev ${inet_iface[$inet_default]} weight ${inet_weight[$inet_default]}"
      break
    fi
  done
fi

if [[ $pong == 1 ]]; then
  multipath_total=1
else
  [ -n "$inet_default" ] && echo "$(date) The default conection with ${inet_gw[$inet_default]} is down" >> $log

  for ((i=1;i<=${#inet_gw[@]};i++)); do
    if [ "$i" != "$inet_default" ]; then
      pong=0
      for letter in $root_dnservers; do
        if(ping -n -c1 -W2 $letter.root-servers.net -I ${inet_ip[$i]} &>/dev/null);then
          pong=1
          # el doble espacio antes de dev _does_mather_
          multipath="$multipath nexthop via ${inet_gw[$i]}  dev ${inet_iface[$i]} weight ${inet_weight[$i]}"
          let multipath_total+=1
          break
        fi
      done
      #if no one answers
      if [[ $pong == 0 ]]; then
        echo "$(date) The conection with ${inet_gw[$i]} is down" >> $log
      fi
    fi
  done
fi

#si todos estan caidos dejo todo como estaba
test -z "${multipath}" && exit 1

while read line; do
  test -z "${line##default*}" && route="${line}"
  test -z "${line##*nexthop*}" && route="$route ${line}"
done < \
<(/sbin/ip route ls table default)

# armo el multipath de los que estan up para poder comparar
# tengo que preguntar xq si hay solo un enlace up, la sintaxis cambia
if [[ $multipath_total > 1 ]]; then
  # el doble espacio antes de proto _does_mather_
  route_new="default  proto static${multipath}"
else
  route_new=${multipath# nexthop }
  route_new=${route_new% weight*}
  route_new="default ${route_new/ dev/dev}  proto static"
fi

#printf "%q\n" "${route}"
#printf "%q\n" "${route_new}"
#echo $multipath
# Ya tengo los 2 multipath, ahora puedo comparar
if [[ "$route" != "$route_new" ]]; then
  # si no son iguales, es hora de cambiar el default gateway
  ip route chg table default default proto static $multipath
  ip route flush cache
  echo "$(date) Changing default gateway to: $multipath" >> $log
fi
