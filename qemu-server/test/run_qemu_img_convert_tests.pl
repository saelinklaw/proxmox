#!/usr/bin/perl

use strict;
use warnings;

use lib qw(..);

use Test::More;
use Test::MockModule;

use PVE::QemuServer;

my $vmid = 8006;
my $storage_config = {
    ids => {
	local => {
	    content => {
		images => 1,
	    },
	    path => "/var/lib/vz",
	    type => "dir",
	    shared => 0,
	},
	"rbd-store" => {
	    monhost => "127.0.0.42,127.0.0.21,::1",
	    content => {
		images => 1
	    },
	    type => "rbd",
	    pool => "cpool",
	    username => "admin",
	    shared => 1
	},
	"local-lvm" => {
	    vgname => "pve",
	    bwlimit => "restore=1024",
	    type => "lvmthin",
	    thinpool => "data",
	    content => {
		images => 1,
	    }
	},
	"zfs-over-iscsi" => {
	    type => "zfs",
	    iscsiprovider => "LIO",
	    lio_tpg => "tpg1",
	    portal => "127.0.0.1",
	    target => "iqn.2019-10.org.test:foobar",
	    pool => "tank",
	}
    }
};

my $tests = [
    {
	name => 'qcow2raw',
	parameters => [ "local:$vmid/vm-$vmid-disk-0.qcow2", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "qcow2", "-O", "raw",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.qcow2", "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw"
	],
    },
    {
	name => "raw2qcow2",
	parameters => [ "local:$vmid/vm-$vmid-disk-0.raw", "local:$vmid/vm-$vmid-disk-0.qcow2", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "-O", "qcow2",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw", "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.qcow2"
	]
    },
    {
	name => "local2rbd",
	parameters => [ "local:$vmid/vm-$vmid-disk-0.raw", "rbd-store:vm-$vmid-disk-0", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "-O", "raw",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw", "rbd:cpool/vm-$vmid-disk-0:mon_host=127.0.0.42;127.0.0.21;[\\:\\:1]:auth_supported=none"
	]
    },
    {
	name => "rbd2local",
	parameters => [ "rbd-store:vm-$vmid-disk-0", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "-O", "raw",
	    "rbd:cpool/vm-$vmid-disk-0:mon_host=127.0.0.42;127.0.0.21;[\\:\\:1]:auth_supported=none", "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw"
	]
    },
    {
	name => "local2zos",
	parameters => [ "local:$vmid/vm-$vmid-disk-0.raw", "zfs-over-iscsi:vm-$vmid-disk-0", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "--target-image-opts",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	    "file.driver=iscsi,file.transport=tcp,file.initiator-name=foobar,file.portal=127.0.0.1,file.target=iqn.2019-10.org.test:foobar,file.lun=1,driver=raw"
	]
    },
    {
	name => "zos2local",
	parameters => [ "zfs-over-iscsi:vm-$vmid-disk-0", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "--image-opts", "-O", "raw",
	    "file.driver=iscsi,file.transport=tcp,file.initiator-name=foobar,file.portal=127.0.0.1,file.target=iqn.2019-10.org.test:foobar,file.lun=1,driver=raw",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	]
    },
    {
	name => "zos2rbd",
	parameters => [ "zfs-over-iscsi:vm-$vmid-disk-0", "rbd-store:vm-$vmid-disk-0", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "--image-opts", "-O", "raw",
	    "file.driver=iscsi,file.transport=tcp,file.initiator-name=foobar,file.portal=127.0.0.1,file.target=iqn.2019-10.org.test:foobar,file.lun=1,driver=raw",
	    "rbd:cpool/vm-$vmid-disk-0:mon_host=127.0.0.42;127.0.0.21;[\\:\\:1]:auth_supported=none"
	]
    },
    {
	name => "rbd2zos",
	parameters => [ "rbd-store:vm-$vmid-disk-0", "zfs-over-iscsi:vm-$vmid-disk-0", 1024*10, undef, 0  ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "--target-image-opts",
	    "rbd:cpool/vm-$vmid-disk-0:mon_host=127.0.0.42;127.0.0.21;[\\:\\:1]:auth_supported=none",
	    "file.driver=iscsi,file.transport=tcp,file.initiator-name=foobar,file.portal=127.0.0.1,file.target=iqn.2019-10.org.test:foobar,file.lun=1,driver=raw",
	]
    },
    {
	name => "local2lvmthin",
	parameters => [ "local:$vmid/vm-$vmid-disk-0.raw", "local-lvm:vm-$vmid-disk-0", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "-O", "raw",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	    "/dev/pve/vm-$vmid-disk-0",
	]
    },
    {
	name => "lvmthin2local",
	parameters => [ "local-lvm:vm-$vmid-disk-0", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "-O", "raw",
	    "/dev/pve/vm-$vmid-disk-0",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	]
    },
    {
	name => "zeroinit",
	parameters => [ "local-lvm:vm-$vmid-disk-0", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 1 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "raw", "-O", "raw",
	    "/dev/pve/vm-$vmid-disk-0",
	    "zeroinit:/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	]
    },
    {
	name => "notexistingstorage",
	parameters => [ "local-lvm:vm-$vmid-disk-0", "not-existing:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 1 ],
	expected => "storage 'not-existing' does not exist\n",
    },
    {
	name => "vmdkfile",
	parameters => [ "./test.vmdk", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-f", "vmdk", "-O", "raw",
	    "./test.vmdk",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	]
    },
    {
	name => "notexistingfile",
	parameters => [ "/foo/bar", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => "source '/foo/bar' is not a valid volid nor path for qemu-img convert\n",
    },
    {
	name => "efidisk",
	parameters => [ "/usr/share/kvm/OVMF_VARS-pure-efi.fd", "local:$vmid/vm-$vmid-disk-0.raw", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "-O", "raw",
	    "/usr/share/kvm/OVMF_VARS-pure-efi.fd",
	    "/var/lib/vz/images/$vmid/vm-$vmid-disk-0.raw",
	]
    },
    {
	name => "efi2zos",
	parameters => [ "/usr/share/kvm/OVMF_VARS-pure-efi.fd", "zfs-over-iscsi:vm-$vmid-disk-0", 1024*10, undef, 0 ],
	expected => [
	    "/usr/bin/qemu-img", "convert", "-p", "-n", "--target-image-opts",
	    "/usr/share/kvm/OVMF_VARS-pure-efi.fd",
	    "file.driver=iscsi,file.transport=tcp,file.initiator-name=foobar,file.portal=127.0.0.1,file.target=iqn.2019-10.org.test:foobar,file.lun=1,driver=raw",
	]
    }
];

my $command;

my $storage_module = Test::MockModule->new("PVE::Storage");
$storage_module->mock(
    config => sub {
	return $storage_config;
    },
    activate_volumes => sub {
	return 1;
    }
);

my $lio_module = Test::MockModule->new("PVE::Storage::LunCmd::LIO");
$lio_module->mock(
    run_lun_command => sub {
	return 1;
    }
);

# we use the exported run_command so we have to mock it there
my $zfsplugin_module = Test::MockModule->new("PVE::Storage::ZFSPlugin");
$zfsplugin_module->mock(
    run_command => sub {
	return 1;
    }
);

# we use the exported run_command so we have to mock it there
my $qemu_server_module = Test::MockModule->new("PVE::QemuServer");
$qemu_server_module->mock(
    run_command => sub {
	$command = shift;
    },
    get_initiator_name => sub {
	return "foobar";
    }
);

foreach my $test (@$tests) {
    my $name = $test->{name};
    my $expected = $test->{expected};
    eval { PVE::QemuServer::qemu_img_convert(@{$test->{parameters}}) };
    if (my $err = $@) {
	is ($err, $expected, $name);
    } elsif (defined($command)) {
	is_deeply($command, $expected, $name);
	$command = undef;
    } else {
	fail($name);
	note("no command")
    }
}

done_testing();
