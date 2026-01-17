  #更新内核
  sudo -s
  mkdir kernel-rpms && cd mkdir kernel-rpms
  wget -N https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/kernel-ml-5.15.63-1.el7.x86_64.rpm
  wget -N https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/kernel-ml-devel-5.15.63-1.el7.x86_64.rpm
  wget -N https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/kernel-ml-headers-5.15.63-1.el7.x86_64.rpm
  wget -N https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/kernel-ml-tools-5.15.63-1.el7.x86_64.rpm
  wget -N https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/kernel-ml-tools-libs-5.15.63-1.el7.x86_64.rpm
  wget -N https://chfs.sxxpqp.top:8443/chfs/shared/centos/7/kernel-ml-tools-libs-devel-5.15.63-1.el7.x86_64.rpm
  yum localinstall kernel-ml-* -y --skip-broken
  yum install -y grub2-pc
  sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=0/' /etc/default/grub
  grub2-mkconfig -o /boot/grub2/grub.cfg
  reboot