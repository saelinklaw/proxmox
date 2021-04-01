package PVE::Storage::LVMPlugin;

use strict;
use warnings;

use IO::File;

use PVE::Tools qw(run_command trim);
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

# lvm helper functions

my $ignore_no_medium_warnings = sub {
    my $line = shift;
    # ignore those, most of the time they're from (virtual) IPMI/iKVM devices
    # and just spam the log..
    if ($line !~ /open failed: No medium found/) {
	print STDERR "$line\n";
    }
};

sub lvm_pv_info {
    my ($device) = @_;

    die "no device specified" if !$device;

    my $has_label = 0;

    my $cmd = ['/usr/bin/file', '-L', '-s', $device];
    run_command($cmd, outfunc => sub {
	my $line = shift;
	$has_label = 1 if $line =~ m/LVM2/;
    });

    return undef if !$has_label;

    $cmd = ['/sbin/pvs', '--separator', ':', '--noheadings', '--units', 'k',
	    '--unbuffered', '--nosuffix', '--options',
	    'pv_name,pv_size,vg_name,pv_uuid', $device];

    my $pvinfo;
    run_command($cmd, outfunc => sub {
	my $line = shift;

	$line = trim($line);

	my ($pvname, $size, $vgname, $uuid) = split(':', $line);

	die "found multiple pvs entries for device '$device'\n"
	    if $pvinfo;

	$pvinfo = {
	    pvname => $pvname,
	    size => int($size),
	    vgname => $vgname,
	    uuid => $uuid,
	};
    });

    return $pvinfo;
}

sub clear_first_sector {
    my ($dev) = shift;

    if (my $fh = IO::File->new($dev, "w")) {
	my $buf = 0 x 512;
	syswrite $fh, $buf;
	$fh->close();
    }
}

sub lvm_create_volume_group {
    my ($device, $vgname, $shared) = @_;

    my $res = lvm_pv_info($device);

    if ($res->{vgname}) {
	return if $res->{vgname} eq $vgname; # already created
	die "device '$device' is already used by volume group '$res->{vgname}'\n";
    }

    clear_first_sector($device); # else pvcreate fails

    # we use --metadatasize 250k, which reseults in "pe_start = 512"
    # so pe_start is aligned on a 128k boundary (advantage for SSDs)
    my $cmd = ['/sbin/pvcreate', '--metadatasize', '250k', $device];

    run_command($cmd, errmsg => "pvcreate '$device' error");

    $cmd = ['/sbin/vgcreate', $vgname, $device];
    # push @$cmd, '-c', 'y' if $shared; # we do not use this yet

    run_command($cmd, errmsg => "vgcreate $vgname $device error", errfunc => $ignore_no_medium_warnings, outfunc => $ignore_no_medium_warnings);
}

sub lvm_vgs {
    my ($includepvs) = @_;

    my $cmd = ['/sbin/vgs', '--separator', ':', '--noheadings', '--units', 'b',
	       '--unbuffered', '--nosuffix', '--options'];

    my $cols = [qw(vg_name vg_size vg_free lv_count)];

    if ($includepvs) {
	push @$cols, qw(pv_name pv_size pv_free);
    }

    push @$cmd, join(',', @$cols);

    my $vgs = {};
    eval {
	run_command($cmd, outfunc => sub {
	    my $line = shift;
	    $line = trim($line);

	    my ($name, $size, $free, $lvcount, $pvname, $pvsize, $pvfree) = split (':', $line);

	    $vgs->{$name} //= {
		size => int ($size),
		free => int ($free),
		lvcount => int($lvcount)
	    };

	    if (defined($pvname) && defined($pvsize) && defined($pvfree)) {
		push @{$vgs->{$name}->{pvs}}, {
		    name => $pvname,
		    size => int($pvsize),
		    free => int($pvfree),
		};
	    }
	},
	errfunc => $ignore_no_medium_warnings,
	);
    };
    my $err = $@;

    # just warn (vgs return error code 5 if clvmd does not run)
    # but output is still OK (list without clustered VGs)
    warn $err if $err;

    return $vgs;
}

sub lvm_list_volumes {
    my ($vgname) = @_;

    my $option_list = 'vg_name,lv_name,lv_size,lv_attr,pool_lv,data_percent,metadata_percent,snap_percent,uuid,tags,metadata_size,time';

    my $cmd = [
	'/sbin/lvs', '--separator', ':', '--noheadings', '--units', 'b',
	'--unbuffered', '--nosuffix',
	'--config', 'report/time_format="%s"',
	'--options', $option_list,
    ];

    push @$cmd, $vgname if $vgname;

    my $lvs = {};
    run_command($cmd, outfunc => sub {
	my $line = shift;

	$line = trim($line);

	my ($vg_name, $lv_name, $lv_size, $lv_attr, $pool_lv, $data_percent, $meta_percent, $snap_percent, $uuid, $tags, $meta_size, $ctime) = split(':', $line);
	return if !$vg_name;
	return if !$lv_name;

	my $lv_type = substr($lv_attr, 0, 1);

	my $d = {
	    lv_size => int($lv_size),
	    lv_type => $lv_type,
	};
	$d->{pool_lv} = $pool_lv if $pool_lv;
	$d->{tags} = $tags if $tags;
	$d->{ctime} = $ctime;

	if ($lv_type eq 't') {
	    $data_percent ||= 0;
	    $meta_percent ||= 0;
	    $snap_percent ||= 0;
	    $d->{metadata_size} = int($meta_size);
	    $d->{metadata_used} = int(($meta_percent * $meta_size)/100);
	    $d->{used} = int(($data_percent * $lv_size)/100);
	}
	$lvs->{$vg_name}->{$lv_name} = $d;
    },
    errfunc => $ignore_no_medium_warnings,
    );

    return $lvs;
}

# Configuration

sub type {
    return 'lvm';
}

sub plugindata {
    return {
	content => [ {images => 1, rootdir => 1}, { images => 1 }],
    };
}

sub properties {
    return {
	vgname => {
	    description => "Volume group name.",
	    type => 'string', format => 'pve-storage-vgname',
	},
	base => {
	    description => "Base volume. This volume is automatically activated.",
	    type => 'string', format => 'pve-volume-id',
	},
	saferemove => {
	    description => "Zero-out data when removing LVs.",
	    type => 'boolean',
	},
	saferemove_throughput => {
	    description => "Wipe throughput (cstream -t parameter value).",
	    type => 'string',
	},
	tagged_only => {
	    description => "Only use logical volumes tagged with 'pve-vm-ID'.",
	    type => 'boolean',
	}
    };
}

sub options {
    return {
	vgname => { fixed => 1 },
	nodes => { optional => 1 },
	shared => { optional => 1 },
	disable => { optional => 1 },
	saferemove => { optional => 1 },
	saferemove_throughput => { optional => 1 },
	content => { optional => 1 },
	base => { fixed => 1, optional => 1 },
	tagged_only => { optional => 1 },
	bwlimit => { optional => 1 },
    };
}

# Storage implementation

sub on_add_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    if (my $base = $scfg->{base}) {
	my ($baseid, $volname) = PVE::Storage::parse_volume_id($base);

	my $cfg = PVE::Storage::config();
	my $basecfg = PVE::Storage::storage_config ($cfg, $baseid, 1);
	die "base storage ID '$baseid' does not exist\n" if !$basecfg;

	# we only support iscsi for now
	die "unsupported base type '$basecfg->{type}'"
	    if $basecfg->{type} ne 'iscsi';

	my $path = PVE::Storage::path($cfg, $base);

	PVE::Storage::activate_storage($cfg, $baseid);

	lvm_create_volume_group($path, $scfg->{vgname}, $scfg->{shared});
    }

    return;
}

sub parse_volname {
    my ($class, $volname) = @_;

    PVE::Storage::Plugin::parse_lvm_name($volname);

    if ($volname =~ m/^(vm-(\d+)-\S+)$/) {
	return ('images', $1, $2, undef, undef, undef, 'raw');
    }

    die "unable to parse lvm volume name '$volname'\n";
}

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    die "lvm snapshot is not implemented"if defined($snapname);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $vg = $scfg->{vgname};

    my $path = "/dev/$vg/$name";

    return wantarray ? ($path, $vmid, $vtype) : $path;
}

sub create_base {
    my ($class, $storeid, $scfg, $volname) = @_;

    die "can't create base images in lvm storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "can't clone images in lvm storage\n";
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix) = @_;

    my $vg = $scfg->{vgname};

    my $lvs = lvm_list_volumes($vg);

    my $disk_list = [ keys %{$lvs->{$vg}} ];

    return PVE::Storage::Plugin::get_next_vm_diskname($disk_list, $storeid, $vmid, undef, $scfg);
}

sub lvcreate {
    my ($vg, $name, $size, $tags) = @_;

    if ($size =~ m/\d$/) { # no unit is given
	$size .= "k"; # default to kilobytes
    }

    my $cmd = ['/sbin/lvcreate', '-aly', '--size', $size, '--name', $name];
    for my $tag (@$tags) {
	push @$cmd, '--addtag', $tag;
    }
    push @$cmd, $vg;

    run_command($cmd, errmsg => "lvcreate '$vg/$name' error");
}

sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - sould be 'vm-$vmid-*'\n"
	if  $name && $name !~ m/^vm-$vmid-/;

    my $vgs = lvm_vgs();

    my $vg = $scfg->{vgname};

    die "no such volume group '$vg'\n" if !defined ($vgs->{$vg});

    my $free = int($vgs->{$vg}->{free});

    die "not enough free space ($free < $size)\n" if $free < $size;

    $name = $class->find_free_diskname($storeid, $scfg, $vmid)
	if !$name;

    lvcreate($vg, $name, $size, ["pve-vm-$vmid"]);

    return $name;
}

sub free_image {
    my ($class, $storeid, $scfg, $volname, $isBase) = @_;

    my $vg = $scfg->{vgname};

    # we need to zero out LVM data for security reasons
    # and to allow thin provisioning

    my $zero_out_worker = sub {
	print "zero-out data on image $volname (/dev/$vg/del-$volname)\n";

	# wipe throughput up to 10MB/s by default; may be overwritten with saferemove_throughput
	my $throughput = '-10485760';
	if ($scfg->{saferemove_throughput}) {
		$throughput = $scfg->{saferemove_throughput};
	}

	my $cmd = [
		'/usr/bin/cstream',
		'-i', '/dev/zero',
		'-o', "/dev/$vg/del-$volname",
		'-T', '10',
		'-v', '1',
		'-b', '1048576',
		'-t', "$throughput"
	];
	eval { run_command($cmd, errmsg => "zero out finished (note: 'No space left on device' is ok here)"); };
	warn $@ if $@;

	$class->cluster_lock_storage($storeid, $scfg->{shared}, undef, sub {
	    my $cmd = ['/sbin/lvremove', '-f', "$vg/del-$volname"];
	    run_command($cmd, errmsg => "lvremove '$vg/del-$volname' error");
	});
	print "successfully removed volume $volname ($vg/del-$volname)\n";
    };

    my $cmd = ['/sbin/lvchange', '-aly', "$vg/$volname"];
    run_command($cmd, errmsg => "can't activate LV '$vg/$volname' to zero-out its data");
    $cmd = ['/sbin/lvchange', '--refresh', "$vg/$volname"];
    run_command($cmd, errmsg => "can't refresh LV '$vg/$volname' to zero-out its data");

    if ($scfg->{saferemove}) {
	# avoid long running task, so we only rename here
	$cmd = ['/sbin/lvrename', $vg, $volname, "del-$volname"];
	run_command($cmd, errmsg => "lvrename '$vg/$volname' error");
	return $zero_out_worker;
    } else {
	my $tmpvg = $scfg->{vgname};
	$cmd = ['/sbin/lvremove', '-f', "$tmpvg/$volname"];
	run_command($cmd, errmsg => "lvremove '$tmpvg/$volname' error");
    }

    return undef;
}

my $check_tags = sub {
    my ($tags) = @_;

    return defined($tags) && $tags =~ /(^|,)pve-vm-\d+(,|$)/;
};

sub list_images {
    my ($class, $storeid, $scfg, $vmid, $vollist, $cache) = @_;

    my $vgname = $scfg->{vgname};

    $cache->{lvs} = lvm_list_volumes() if !$cache->{lvs};

    my $res = [];

    if (my $dat = $cache->{lvs}->{$vgname}) {

	foreach my $volname (keys %$dat) {

	    next if $volname !~ m/^vm-(\d+)-/;
	    my $owner = $1;

	    my $info = $dat->{$volname};

	    next if $scfg->{tagged_only} && !&$check_tags($info->{tags});

	    # Allow mirrored and RAID LVs
	    next if $info->{lv_type} !~ m/^[-mMrR]$/;

	    my $volid = "$storeid:$volname";

	    if ($vollist) {
		my $found = grep { $_ eq $volid } @$vollist;
		next if !$found;
	    } else {
		next if defined($vmid) && ($owner ne $vmid);
	    }

	    push @$res, {
		volid => $volid, format => 'raw', size => $info->{lv_size}, vmid => $owner,
		ctime => $info->{ctime},
	    };
	}
    }

    return $res;
}

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{vgs} = lvm_vgs() if !$cache->{vgs};

    my $vgname = $scfg->{vgname};

     if (my $info = $cache->{vgs}->{$vgname}) {
	return ($info->{size}, $info->{free}, $info->{size} - $info->{free}, 1);
    }

    return undef;
}

sub activate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{vgs} = lvm_vgs() if !$cache->{vgs};

    # In LVM2, vgscans take place automatically;
    # this is just to be sure
    if ($cache->{vgs} && !$cache->{vgscaned} &&
	!$cache->{vgs}->{$scfg->{vgname}}) {
	$cache->{vgscaned} = 1;
	my $cmd = ['/sbin/vgscan', '--ignorelockingfailure', '--mknodes'];
	eval { run_command($cmd, outfunc => sub {}); };
	warn $@ if $@;
    }

    # we do not acticate any volumes here ('vgchange -aly')
    # instead, volumes are activate individually later
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $cmd = ['/sbin/vgchange', '-aln', $scfg->{vgname}];
    run_command($cmd, errmsg => "can't deactivate VG '$scfg->{vgname}'");
}

sub activate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;
    #fix me lvmchange is not provided on
    my $path = $class->path($scfg, $volname, $snapname);

    my $lvm_activate_mode = 'ey';

    my $cmd = ['/sbin/lvchange', "-a$lvm_activate_mode", $path];
    run_command($cmd, errmsg => "can't activate LV '$path'");
    $cmd = ['/sbin/lvchange', '--refresh', $path];
    run_command($cmd, errmsg => "can't refresh LV '$path' for activation");
}

sub deactivate_volume {
    my ($class, $storeid, $scfg, $volname, $snapname, $cache) = @_;

    my $path = $class->path($scfg, $volname, $snapname);
    return if ! -b $path;

    my $cmd = ['/sbin/lvchange', '-aln', $path];
    run_command($cmd, errmsg => "can't deactivate LV '$path'");
}

sub volume_resize {
    my ($class, $scfg, $storeid, $volname, $size, $running) = @_;

    $size = ($size/1024/1024) . "M";

    my $path = $class->path($scfg, $volname);
    my $cmd = ['/sbin/lvextend', '-L', $size, $path];

    $class->cluster_lock_storage($storeid, $scfg->{shared}, undef, sub {
	run_command($cmd, errmsg => "error resizing volume '$path'");
    });

    return 1;
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;
    my $path = $class->filesystem_path($scfg, $volname);

    my $cmd = ['/sbin/lvs', '--separator', ':', '--noheadings', '--units', 'b',
	       '--unbuffered', '--nosuffix', '--options', 'lv_size', $path];

    my $size;
    run_command($cmd, timeout => $timeout, errmsg => "can't get size of '$path'",
	outfunc => sub {
	    $size = int(shift);
    });
    return wantarray ? ($size, 'raw', 0, undef) : $size;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "lvm snapshot is not implemented";
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "lvm snapshot rollback is not implemented";
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    die "lvm snapshot delete is not implemented";
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid, $volname, $snapname, $running) = @_;

    my $features = {
	copy => { base => 1, current => 1},
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
	$class->parse_volname($volname);

    my $key = undef;
    if($snapname){
	$key = 'snap';
    }else{
	$key =  $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;
    return () if defined($snapshot); # lvm-thin only
    return volume_import_formats($class, $scfg, $storeid, $volname, $base_snapshot, $with_snapshots);
}

sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots) = @_;
    die "volume export format $format not available for $class\n"
	if $format ne 'raw+size';
    die "cannot export volumes together with their snapshots in $class\n"
	if $with_snapshots;
    die "cannot export a snapshot in $class\n" if defined($snapshot);
    die "cannot export an incremental stream in $class\n" if defined($base_snapshot);
    my $file = $class->path($scfg, $volname, $storeid);
    my $size;
    # should be faster than querying LVM, also checks for the device file's availability
    run_command(['/sbin/blockdev', '--getsize64', $file], outfunc => sub {
	my ($line) = @_;
	die "unexpected output from /sbin/blockdev: $line\n" if $line !~ /^(\d+)$/;
	$size = int($1);
    });
    PVE::Storage::Plugin::write_common_header($fh, $size);
    run_command(['dd', "if=$file", "bs=64k"], output => '>&'.fileno($fh));
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $base_snapshot, $with_snapshots) = @_;
    return () if $with_snapshots; # not supported
    return () if defined($base_snapshot); # not supported
    return ('raw+size');
}

sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $base_snapshot, $with_snapshots, $allow_rename) = @_;
    die "volume import format $format not available for $class\n"
	if $format ne 'raw+size';
    die "cannot import volumes together with their snapshots in $class\n"
	if $with_snapshots;
    die "cannot import an incremental stream in $class\n" if defined($base_snapshot);

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $file_format) =
	$class->parse_volname($volname);
    die "cannot import format $format into a file of format $file_format\n"
	if $file_format ne 'raw';

    my $vg = $scfg->{vgname};
    my $lvs = lvm_list_volumes($vg);
    if ($lvs->{$vg}->{$volname}) {
	die "volume $vg/$volname already exists\n" if !$allow_rename;
	warn "volume $vg/$volname already exists - importing with a different name\n";
	$name = undef;
    }

    my ($size) = PVE::Storage::Plugin::read_common_header($fh);
    $size = int($size/1024);

    eval {
	my $allocname = $class->alloc_image($storeid, $scfg, $vmid, 'raw', $name, $size);
	my $oldname = $volname;
	$volname = $allocname;
	if (defined($name) && $allocname ne $oldname) {
	    die "internal error: unexpected allocated name: '$allocname' != '$oldname'\n";
	}
	my $file = $class->path($scfg, $volname, $storeid)
	    or die "internal error: failed to get path to newly allocated volume $volname\n";

	$class->volume_import_write($fh, $file);
    };
    if (my $err = $@) {
	eval { $class->free_image($storeid, $scfg, $volname, 0) };
	warn $@ if $@;
	die $err;
    }

    return "$storeid:$volname";
}

sub volume_import_write {
    my ($class, $input_fh, $output_file) = @_;
    run_command(['dd', "of=$output_file", 'bs=64k'],
	input => '<&'.fileno($input_fh));
}

1;
