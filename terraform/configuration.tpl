[cluster-name]
${ cluster_name }

[cluster-key-name]
${ cluster_key_name }

[cluster-ssh-key]
cluster_key.priv (in this directory)

[node-ssh-user]
ubuntu

[control-plane-networking]
Public DNS: ${ control_plane.public_dns }
Public IP: ${ control_plane.public_ip }
Private DNS: ${ control_plane.private_dns }
Private IP: ${ control_plane.private_ip }
%{ for i, w in workers }
[worker-${ i }-networking]
Public DNS: ${ w.public_dns }
Public IP: ${ w.public_ip }
Private DNS: ${ w.private_dns }
Private IP: ${ w.private_ip }
%{ endfor ~}
