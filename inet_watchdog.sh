#!/bin/bash

source firewall.conf

root_nameservers="B C D E F I J K L M"

pong=0
for ((i=1;i<=${#gw[@]};i++)); do
  for letter in $root_nameservers; do  
    if (ping -c1 -W2 $letter.root-servers.net -I ${gw_ip[$i]} &>/dev/null); then  
      pong=1
      echo ip ro del default
      echo ip ro add default via table enlace$i
      break  
    fi  
  done
  [ $pong == 1 ] && break
done

echo -e "Subject: Cambio de Enlace en $(hostname -f)\n$(date) Se conmuto el enlace a ${gw_name[$i]}" | sendmail $mail
