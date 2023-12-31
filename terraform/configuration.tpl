[cluster-name]
${ cluster_name }

[cluster-key-name]
${ cluster_key_name }

[cluster-ssh-key]
${ cluster_private_key_openssh }

[node-ssh-user]
ubuntu

[control-plane-networking]
Public DNS: ${ control_plane_public_dns }
Public IP: ${ control_plane_public_ip }
Private IP: ${ control_plane_private_ip }

[worker-0-networking]
Public DNS: ${ worker_0_public_dns }
Public IP: ${ worker_0_public_ip }
Private IP: ${ worker_0_private_ip }

[worker-1-networking]
Public DNS: ${ worker_1_public_dns }
Public IP: ${ worker_1_public_ip }
Private IP: ${ worker_1_private_ip }
