#!/usr/bin/env bash
set -euo pipefail

# -------- configurable settings --------
LOCATION="eastus"                     # choose your preferred region
RG="rg-nestedvm-demo"
VNET="vnet-nestedvm"
SUBNET="subnet-default"
BASTION_SUBNET="AzureBastionSubnet"   # must be exactly this name
NSG="nsg-nestedvm"
NIC="nic-nestedvm"
VMNAME="vm-nested-4x16"
VM_SIZE="Standard_D4s_v5"             # 4 vCPU / 16 GiB, supports nested virtualization
IMAGE="MicrosoftWindowsServer:WindowsServer:2022-datacenter-azure-edition:latest"
ADMIN_USER="azureadmin"
BASTION_NAME="bastion-nestedvm"
BASTION_PIP="pip-bastion"
# --------------------------------------

echo "==> Creating resource group..."
az group create -n "$RG" -l "$LOCATION" 1>/dev/null

echo "==> Creating virtual network with default and Bastion subnets..."
az network vnet create \
  -g "$RG" -n "$VNET" \
  --address-prefixes 10.10.0.0/16 \
  --subnet-name "$SUBNET" \
  --subnet-prefix 10.10.1.0/24 1>/dev/null

# Add the AzureBastionSubnet with a minimum /27 prefix
az network vnet subnet create \
  -g "$RG" \
  --vnet-name "$VNET" \
  -n "$BASTION_SUBNET" \
  --address-prefixes 10.10.2.0/27 1>/dev/null

echo "==> Creating Network Security Group (NSG)..."
az network nsg create -g "$RG" -n "$NSG" 1>/dev/null

# No inbound RDP rules — Bastion will handle access
# Only outbound rules remain as per Azure defaults

echo "==> Creating NIC without public IP..."
SUBNET_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "$SUBNET" --query id -o tsv)

az network nic create \
  -g "$RG" -n "$NIC" \
  --subnet "$SUBNET_ID" \
  --network-security-group "$NSG" \
  --private-ip-address-version IPv4 1>/dev/null

# Prompt for Windows admin password
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  read -r -s -p "Enter a strong Windows admin password for ${ADMIN_USER}: " ADMIN_PASSWORD
  echo
fi

echo "==> Creating the VM with no public IP..."
az vm create \
  -g "$RG" -n "$VMNAME" \
  --size "$VM_SIZE" \
  --image "$IMAGE" \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASSWORD" \
  --nics "$NIC" \
  --os-disk-name "${VMNAME}-osdisk" \
  --os-disk-size-gb 127 \
  --os-disk-delete-option Delete \
  --enable-vtpm true \
  --enable-secure-boot true \
  --license-type Windows_Server \
  --tags purpose=nested-virt-demo 1>/dev/null

# Enable accelerated networking if possible
set +e
az network nic update -g "$RG" -n "$NIC" --accelerated-networking true 1>/dev/null
set -e

echo "==> Creating public IP for Bastion..."
az network public-ip create \
  -g "$RG" -n "$BASTION_PIP" \
  --sku Standard \
  --allocation-method Static 1>/dev/null

echo "==> Deploying Azure Bastion..."
az network bastion create \
  -g "$RG" -n "$BASTION_NAME" \
  --public-ip-address "$BASTION_PIP" \
  --vnet-name "$VNET" \
  --location "$LOCATION" 1>/dev/null

BASTION_PUBLIC_IP=$(az network public-ip show -g "$RG" -n "$BASTION_PIP" --query ipAddress -o tsv)

echo "============================================================"
echo " VM deployed!"
echo " Name:            $VMNAME"
echo " Size:            $VM_SIZE"
echo " OS:              Windows Server 2022 Datacenter (Azure Edition)"
echo " Resource Group:  $RG"
echo " Location:        $LOCATION"
echo " VM Public IP:    None (private only)"
echo " Bastion Name:    $BASTION_NAME"
echo " Bastion Public IP: $BASTION_PUBLIC_IP"
echo " Admin username:  $ADMIN_USER"
echo "============================================================"
echo "Access via Azure Portal > Bastion to RDP without exposing port 3389."
