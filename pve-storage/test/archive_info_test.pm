package PVE::Storage::TestArchiveInfo;

use strict;
use warnings;

use lib qw(..);

use PVE::Storage;
use Test::More;

my $vmid = 16110;

# an array of test cases, each test is comprised of the following keys:
# description => to identify a single test
# archive     => the input filename for archive_info
# expected    => the hash that archive_info returns
#
# most of them are created further below
my $tests = [
    # backup archives
    {
	description => 'Backup archive, lxc, tgz, future millenium',
	archive     => "backup/vzdump-lxc-$vmid-3070_01_01-00_00_00.tgz",
	expected    => {
	    'filename'     => "vzdump-lxc-$vmid-3070_01_01-00_00_00.tgz",
	    'logfilename'  => "vzdump-lxc-$vmid-3070_01_01-00_00_00.log",
	    'type'         => 'lxc',
	    'format'       => 'tar',
	    'decompressor' => ['tar', '-z'],
	    'compression'  => 'gz',
	    'vmid'         => $vmid,
	    'ctime'        => 60*60*24 * (365*1100 + 267),
	    'is_std_name'  => 1,
	},
    },
    {
	description => 'Backup archive, lxc, tgz, very old',
	archive     => "backup/vzdump-lxc-$vmid-1970_01_01-02_00_30.tgz",
	expected    => {
	    'filename'     => "vzdump-lxc-$vmid-1970_01_01-02_00_30.tgz",
	    'logfilename'  => "vzdump-lxc-$vmid-1970_01_01-02_00_30.log",
	    'type'         => 'lxc',
	    'format'       => 'tar',
	    'decompressor' => ['tar', '-z'],
	    'compression'  => 'gz',
	    'vmid'         => $vmid,
	    'ctime'        => 60*60*2 + 30,
	    'is_std_name'  => 1,
	},
    },
    {
	description => 'Backup archive, lxc, tgz',
	archive     => "backup/vzdump-lxc-$vmid-2020_03_30-21_39_30.tgz",
	expected    => {
	    'filename'     => "vzdump-lxc-$vmid-2020_03_30-21_39_30.tgz",
	    'logfilename'  => "vzdump-lxc-$vmid-2020_03_30-21_39_30.log",
	    'type'         => 'lxc',
	    'format'       => 'tar',
	    'decompressor' => ['tar', '-z'],
	    'compression'  => 'gz',
	    'vmid'         => $vmid,
	    'ctime'        => 1585604370,
	    'is_std_name'  => 1,
	},
    },
    {
	description => 'Backup archive, openvz, tgz',
	archive     => "backup/vzdump-openvz-$vmid-2020_03_30-21_39_30.tgz",
	expected    => {
	    'filename'     => "vzdump-openvz-$vmid-2020_03_30-21_39_30.tgz",
	    'logfilename'  => "vzdump-openvz-$vmid-2020_03_30-21_39_30.log",
	    'type'         => 'openvz',
	    'format'       => 'tar',
	    'decompressor' => ['tar', '-z'],
	    'compression'  => 'gz',
	    'vmid'         => $vmid,
	    'ctime'        => 1585604370,
	    'is_std_name'  => 1,
	},
    },
    {
	description => 'Backup archive, custom dump directory, qemu, tgz',
	archive     => "/here/be/Back-ups/vzdump-qemu-$vmid-2020_03_30-21_39_30.tgz",
	expected    => {
	    'filename'     => "vzdump-qemu-$vmid-2020_03_30-21_39_30.tgz",
	    'logfilename'  => "vzdump-qemu-$vmid-2020_03_30-21_39_30.log",
	    'type'         => 'qemu',
	    'format'       => 'tar',
	    'decompressor' => ['tar', '-z'],
	    'compression'  => 'gz',
	    'vmid'         => $vmid,
	    'ctime'        => 1585604370,
	    'is_std_name'  => 1,
	},
    },
    {
	description => 'Backup archive, none, tgz',
	archive     => "backup/vzdump-qemu-$vmid-whatever-the-name_is_here.tgz",
	expected    => {
	    'filename'     => "vzdump-qemu-$vmid-whatever-the-name_is_here.tgz",
	    'type'         => 'qemu',
	    'format'       => 'tar',
	    'decompressor' => ['tar', '-z'],
	    'compression'  => 'gz',
	    'is_std_name'  => 0,
	},
    },
];

# add new compression fromats to test
my $decompressor = {
    tar => {
	gz  => ['tar', '-z'],
	lzo => ['tar', '--lzop'],
	zst => ['tar', '--zstd'],
    },
    vma => {
	gz  => ['zcat'],
	lzo => ['lzop', '-d', '-c'],
	zst => ['zstd', '-q', '-d', '-c'],
    },
};

my $bkp_suffix = {
    qemu   => [ 'vma', $decompressor->{vma}, ],
    lxc    => [ 'tar', $decompressor->{tar}, ],
    openvz => [ 'tar', $decompressor->{tar}, ],
};

# create more test cases for backup files matches
for my $virt (sort keys %$bkp_suffix) {
    my ($format, $decomp) = $bkp_suffix->{$virt}->@*;

    for my $suffix (sort keys %$decomp) {
	push @$tests, {
	    description => "Backup archive, $virt, $format.$suffix",
	    archive     => "backup/vzdump-$virt-$vmid-2020_03_30-21_12_40.$format.$suffix",
	    expected    => {
		'filename'     => "vzdump-$virt-$vmid-2020_03_30-21_12_40.$format.$suffix",
		'logfilename'  => "vzdump-$virt-$vmid-2020_03_30-21_12_40.log",
		'type'         => "$virt",
		'format'       => "$format",
		'decompressor' => $decomp->{$suffix},
		'compression'  => "$suffix",
		'vmid'         => $vmid,
		'ctime'        => 1585602760,
		'is_std_name'  => 1,
	    },
	};
    }
}


# add compression formats to test failed matches
my $non_bkp_suffix = {
    'openvz' => [ 'zip', 'tgz.lzo', 'tar.bz2', 'zip.gz', '', ],
    'lxc'    => [ 'zip', 'tgz.lzo', 'tar.bz2', 'zip.gz', '', ],
    'qemu'   => [ 'vma.xz', 'vms.gz', 'vmx.zst', '', ],
    'none'   => [ 'tar.gz', ],
};

# create tests for failed matches
for my $virt (sort keys %$non_bkp_suffix) {
    my $suffix = $non_bkp_suffix->{$virt};
    for my $s (@$suffix) {
	my $archive = "backup/vzdump-$virt-$vmid-2020_03_30-21_12_40.$s";
	push @$tests, {
	    description => "Failed match: Backup archive, $virt, $s",
	    archive     => $archive,
	    expected    => "ERROR: couldn't determine archive info from '$archive'\n",
	};
    }
}


plan tests => scalar @$tests;

for my $tt (@$tests) {

    my $got = eval { PVE::Storage::archive_info($tt->{archive}) };
    $got = $@ if $@;

    is_deeply($got, $tt->{expected}, $tt->{description}) || diag(explain($got));
}

done_testing();

1;
