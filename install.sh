#!/bin/bash
# set -o errexit   # abort on nonzero exitstatus
# set -o nounset   # abort on unbound variable
# set -o pipefail  # don't hide errors within pipes

set -uo pipefail

export SERVERS=3
export AGENTS=2
export CILIUM_VERSION=1.14.0

echo "#######################################################"
echo "############### k3d with k3s and cilium ###############"
echo "############### creating cluster with: ################"
echo "############### servers: ${SERVERS} ############################"
echo "############### agents: ${AGENTS} #############################"
echo "#######################################################"
sleep 5

k3d cluster create k3s \
--servers ${SERVERS} \
--servers-memory 6G \
--agents ${AGENTS} \
--agents-memory 8G \
--k3s-arg="--disable=traefik@server:*" \
--k3s-arg="--disable-network-policy@server:*" \
--k3s-arg="--flannel-backend=none@server:*" \
--k3s-arg=feature-gates="NamespaceDefaultLabelName=true@server:*"

echo "#######################################################"
echo "########## starting  docker exec mounts... ############"
echo "#######################################################"

sleep 5
counts=0
counta=0
## le - less than or equal
## lt - less than

echo "#######################################################"
echo "################ mounting servers #####################"
echo "#######################################################"
while [ $counts -lt ${SERVERS} ]
do
    echo "working on docker exec for server:" $counts
    docker exec k3d-k3s-server-$counts sh -c "mount bpffs /sys/fs/bpf -t bpf && mount --make-shared /sys/fs/bpf"
    ((counts++))
    sleep 3
done

echo "#######################################################"
echo "################# mounting agents #####################"
echo "#######################################################"
while [ $counta -lt ${AGENTS} ]
do
    echo "working on docker exec for agent:" $counta
    docker exec k3d-k3s-agent-$counta sh -c "mount bpffs /sys/fs/bpf -t bpf && mount --make-shared /sys/fs/bpf"
    ((counta++))
    sleep 3
done

echo "############################################################"
echo "#### tainting nodes to allow pods to land on ready only ####"
echo "############################################################"
sleep 5
kubectl taint node -l beta.kubernetes.io/instance-type=k3s node.cilium.io/agent-not-ready=true:NoSchedule --overwrite=true
sleep 5
echo "#######################################################"
echo "############# deploying cilium via helm ###############"
echo "#######################################################"
sleep 5
helm repo add cilium https://helm.cilium.io/

helm install cilium cilium/cilium --version=${CILIUM_VERSION} \
    --set global.tag="v${CILIUM_VERSION}" \
    --set externalIPs.enabled=true \
    --set nodePort.enabled=true \
    --set hostPort.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set global.kubeProxyReplacement="strict" --namespace kube-system

until bash -c "kubectl get pods -n kube-system -l k8s-app=cilium | grep 'Init:CreateContainerError'"; do \
    kubectl get pods -n kube-system -l k8s-app=cilium | grep "Running"; \
    is_running=$${?}; \
    if test $${is_running} -eq 0; then \
        echo "time to jump into the next task:" \
        break; \
    else \
        echo "waiting for pods to be in the right state..."
        sleep 5; \
    fi; \
done

counts=0
counta=0

echo "##############################################################"
echo "######## starting  docker exec mounts for servers... #########"
echo "##############################################################"

while [ $counts -lt ${SERVERS} ]
do 
    echo "working on docker exec for node:" $counts
    docker exec k3d-k3s-server-$counts sh -c "mount --make-shared /run/cilium/cgroupv2"
    ((counts++))
    sleep 3
done 

echo "##############################################################"
echo "######## starting  docker exec mounts for agents... ##########"
echo "##############################################################"

while [ $counta -lt ${AGENTS} ]
do
    echo "working on docker exec for agent:" $counta
    docker exec k3d-k3s-agent-$counta sh -c "mount --make-shared /run/cilium/cgroupv2"
    ((counta++))
    sleep
done

counta=0
while [ $counta -lt ${AGENTS} ]
do
  kubectl label --overwrite node k3d-k3s-agent-$counta node-role.kubernetes.io/worker=true
  ((counta++))
done

kubectl get nodes
sleep 5
kubectl get po -A
