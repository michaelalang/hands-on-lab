ssh-keygen -t ecdsa -f id_ecdsa -P ''

SM_USERNAME="$(vault sm_username)"
SM_PASSWORD="$(vault sm_username)"

# download Virtualization Images from https://access.redhat.com/downloads/content/rhel
for img in rhel-10.2-x86_64-kvm.qcow2 rhel-9.8-x86_64-kvm.qcow2 ; do

sudo LIBGUESTFS_BACKEND=direct virt-customize -a ${img}   --ssh-inject root:file:./id_ecdsa.pub   --write '/etc/ssh/sshd_config.d/01-permitrootlogin.conf:PermitRootLogin prohibit-password'   --write '/etc/cloud/cloud.cfg.d/01-permit-root.cfg:disable_root: false'   --selinux-relabel


sudo LIBGUESTFS_BACKEND=direct virt-customize   -a ${img}   --run-command "subscription-manager register --username ${SM_USERNAME} --password ${SM_PASSWORD} --force"   --install podman --install git  --run-command "dnf update -y" --selinux-relabel --run-command "cloud-init clean --logs" --truncate /etc/machine-id --delete "/etc/ssh/ssh_host_*" --delete "/etc/pki/consumer/*" --delete "/etc/pki/entitlement/*"

disk=$(sudo LIBGUESTFS_BACKEND=direct virt-filesystems   --long -h --all   -a ${img} | awk ' /xfs      root/ { print $1 } ')
newimg="$(basename -s qcow2 ${img})img"

# virt-resize does not create the destination disk. It only copies into an
# already-existing image that is the same size or larger than the source.
qemu-img create -f qcow2 "./${newimg}" 100G

sudo LIBGUESTFS_BACKEND=direct virt-resize --expand "${disk}" "./${img}" "./${newimg}"

done
