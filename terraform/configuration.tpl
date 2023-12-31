[cluster-name]
${ cluster_name }

[cluster-key-name]
${ cluster_key_name }

[cluster-ssh-key]
${ cluster_private_key_openssh }

[node-ssh-user]
user = ubuntu

[control-plane-ip-addresses]
Public: ${ control_plane_public_ip }
Private: ${ control_plane_private_ip }

[worker-0-ip-addresses]
Public: ${ worker_0_public_ip }
Private: ${ worker_0_private_ip }

[worker-1-ip-addresses]
Public: ${ worker_1_public_ip }
Private: ${ worker_1_private_ip }