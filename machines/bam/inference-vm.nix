{pkgs, inputs, ...}: let
  domainXML = pkgs.writeText "inference.xml" ''
    <domain type="kvm" xmlns:qemu="http://libvirt.org/schemas/domain/qemu/1.0">
      <name>inference</name>
      <uuid>7d1f4b2a-0000-4000-8000-badc0ffee000</uuid>
      <memory unit="GiB">108</memory>
      <memoryBacking>
        <hugepages><page size="1" unit="GiB"/></hugepages>
        <locked/>
        <nosharepages/>
      </memoryBacking>
      <memtune>
        <hard_limit unit="GiB">116</hard_limit>
      </memtune>
      <vcpu placement="static">28</vcpu>
      <cputune>
        <!-- cluster 0: cores 1-7 (CCD0); vCPU 2n -> CPU, 2n+1 -> SMT sibling -->
        <vcpupin vcpu="0"  cpuset="1"/><vcpupin vcpu="1"  cpuset="17"/>
        <vcpupin vcpu="2"  cpuset="2"/><vcpupin vcpu="3"  cpuset="18"/>
        <vcpupin vcpu="4"  cpuset="3"/><vcpupin vcpu="5"  cpuset="19"/>
        <vcpupin vcpu="6"  cpuset="4"/><vcpupin vcpu="7"  cpuset="20"/>
        <vcpupin vcpu="8"  cpuset="5"/><vcpupin vcpu="9"  cpuset="21"/>
        <vcpupin vcpu="10" cpuset="6"/><vcpupin vcpu="11" cpuset="22"/>
        <vcpupin vcpu="12" cpuset="7"/><vcpupin vcpu="13" cpuset="23"/>
        <!-- cluster 1: cores 9-15 (CCD1) -->
        <vcpupin vcpu="14" cpuset="9"/><vcpupin vcpu="15" cpuset="25"/>
        <vcpupin vcpu="16" cpuset="10"/><vcpupin vcpu="17" cpuset="26"/>
        <vcpupin vcpu="18" cpuset="11"/><vcpupin vcpu="19" cpuset="27"/>
        <vcpupin vcpu="20" cpuset="12"/><vcpupin vcpu="21" cpuset="28"/>
        <vcpupin vcpu="22" cpuset="13"/><vcpupin vcpu="23" cpuset="29"/>
        <vcpupin vcpu="24" cpuset="14"/><vcpupin vcpu="25" cpuset="30"/>
        <vcpupin vcpu="26" cpuset="15"/><vcpupin vcpu="27" cpuset="31"/>
        <emulatorpin cpuset="8,24"/>
      </cputune>
      <os firmware="efi">
        <type arch="x86_64" machine="q35">hvm</type>
        <boot dev="hd"/>
      </os>
      <features>
        <acpi/><apic/>
        <kvm><hint-dedicated state="on"/></kvm>
      </features>
      <cpu mode="host-passthrough" check="none">
        <topology sockets="1" dies="2" cores="7" threads="2"/>
        <cache mode="passthrough"/>
        <feature policy="require" name="topoext"/>
        <feature policy="require" name="invtsc"/>
      </cpu>
      <clock offset="utc">
        <timer name="tsc" present="yes" mode="native"/>
      </clock>
      <devices>
        <!-- RTX PRO 6000: VGA + audio fn, same slot in guest -->
        <hostdev mode="subsystem" type="pci" managed="yes">
          <source><address domain="0x0000" bus="0x01" slot="0x00" function="0x0"/></source>
          <address type="pci" domain="0x0000" bus="0x05" slot="0x00" function="0x0" multifunction="on"/>
        </hostdev>
        <hostdev mode="subsystem" type="pci" managed="yes">
          <source><address domain="0x0000" bus="0x01" slot="0x00" function="0x1"/></source>
          <address type="pci" domain="0x0000" bus="0x05" slot="0x00" function="0x1"/>
        </hostdev>
        <!-- 1TB NVMe controller (already vfio-bound in initrd) -->
        <hostdev mode="subsystem" type="pci" managed="no">
          <source><address domain="0x0000" bus="0x0a" slot="0x00" function="0x0"/></source>
        </hostdev>
        <interface type="bridge">
          <source bridge="br0"/>
          <model type="virtio"/>
          <mac address="52:54:00:6b:a3:01"/>
          <driver name="vhost" queues="2"/>
        </interface>
        <serial type="pty"><target port="0"/></serial>
        <console type="pty"><target type="serial" port="0"/></console>
        <memballoon model="none"/>
      </devices>
      <qemu:commandline>
        <!-- 64-bit MMIO aperture for the 96GB BAR1: 256 GiB -->
        <qemu:arg value="-fw_cfg"/>
        <qemu:arg value="name=opt/ovmf/X-PciMmio64Mb,string=262144"/>
      </qemu:commandline>
    </domain>
  '';
in {
  imports = [inputs.nixvirt.nixosModules.default];
  virtualisation.libvirt = {
    enable = true;
    connections."qemu:///system".domains = [
      {
        definition = domainXML;
        active = true;
      }
    ];
  };
}
