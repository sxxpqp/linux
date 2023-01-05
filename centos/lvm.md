#!/bin/bash
## 创建物理卷
```
pvcreate  /dev/vdb1
```
  Physical volume "/dev/vdb1" successfully created.
## 创建卷组
```
 vgcreate vg1 /dev/vdb1 
```
  Volume group "vg1" successfully created

## 创建逻辑卷
```
lvcreate -n lv1 -L 500M vg1 
lvs
```
## 创建挂载点并挂载
```
mkdir /mnt/lv1
mount /dev/mapper/vg1-lv1  /mnt/lv1/
df -Th |grep /mnt/lv1
```
## **ext4文件系统逻辑卷扩容**

### 将一块新的磁盘配置为物理卷 并加入卷组

```
pvcreate  /dev/vdc
```

  Physical volume "/dev/vdc" successfully created.

```
 vgextend vg1 /dev/vdc
```

  Volume group "vg1" successfully extended

```
vgs
```

  VG  #PV #LV #SN Attr   VSize VFree
  vg1   2   1   0 wz--n- 5.99g 5.50g


### 扩容逻辑卷分区

```
lvextend -L +5G /dev/vg1/lv1 
```

  Size of logical volume vg1/lv1 changed from 500.00 MiB (125 extents) to <5.49 GiB (1405 extents).
  Logical volume vg1/lv1 successfully resized.

```
lvs
```

  LV   VG  Attr       LSize  Pool Origin Data%  Meta%  Move Log Cpy%Sync Convert
  lv1  vg1 -wi-a----- <5.49g      


### 使用resize2fs刷新文件系统

```
resize2fs -f /dev/mapper/

```

### 挂载查看容量

```
df -h
```

## **xfs文件系统逻辑卷扩容**

## 将一块新的磁盘配置为物理卷 并加入卷组

```
pvcreate  /dev/vdd
```

  Physical volume "/dev/vdd" successfully created.

```
 vgextend  vg1 /dev/vdd
```

  Volume group "vg1" successfully extended

```
vgs
```

  VG  #PV #LV #SN Attr   VSize   VFree
  vg1   3   1   0 wz--n- <10.99g 5.50g


## 扩容逻辑卷分区

登录后复制 

```
lvextend -l +100%FREE /dev/vg1/lv1
```

```
lvextend -L +5G /dev/vg1/lv1 
```

  Size of logical volume vg1/lv1 changed from <5.49 GiB (1405 extents) to <10.49 GiB (2685 extents).
  Logical volume vg1/lv1 successfully resized.

## 使用xfs_growfs命令刷新文件系统并挂载

```
xfs_growfs  /dev/mapper/vg1-lv1 
```

xfs_growfs: /dev/mapper/vg1-lv1 is not a mounted XFS filesystem

## 挂载查看容量

```
df -h
```

