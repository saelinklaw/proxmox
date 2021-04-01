package PVE::API2::Disks::Directory;

use strict;
use warnings;

use PVE::Diskmanage;
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Systemd;
use PVE::Tools qw(run_command trim file_set_contents file_get_contents dir_glob_foreach lock_file);

use PVE::API2::Storage::Config;

use base qw(PVE::RESTHandler);

my $SGDISK = '/sbin/sgdisk';
my $MKFS = '/sbin/mkfs';
my $BLKID = '/sbin/blkid';

my $read_ini = sub {
    my ($filename) = @_;

    my $content = file_get_contents($filename);
    my @lines = split /\n/, $content;

    my $result = {};
    my $section;

    foreach my $line (@lines) {
	$line = trim($line);
	if ($line =~ m/^\[([^\]]+)\]/) {
	    $section = $1;
	    if (!defined($result->{$section})) {
		$result->{$section} = {};
	    }
	} elsif ($line =~ m/^(.*?)=(.*)$/) {
	    my ($key, $val) = ($1, $2);
	    if (!$section) {
		warn "key value pair found without section, skipping\n";
		next;
	    }

	    if ($result->{$section}->{$key}) {
		# make duplicate properties to arrays to keep the order
		my $prop = $result->{$section}->{$key};
		if (ref($prop) eq 'ARRAY') {
		    push @$prop, $val;
		} else {
		    $result->{$section}->{$key} = [$prop, $val];
		}
	    } else {
		$result->{$section}->{$key} = $val;
	    }
	}
	# ignore everything else
    }

    return $result;
};

my $write_ini = sub {
    my ($ini, $filename) = @_;

    my $content = "";

    foreach my $sname (sort keys %$ini) {
	my $section = $ini->{$sname};

	$content .= "[$sname]\n";

	foreach my $pname (sort keys %$section) {
	    my $prop = $section->{$pname};

	    if (!ref($prop)) {
		$content .= "$pname=$prop\n";
	    } elsif (ref($prop) eq 'ARRAY') {
		foreach my $val (@$prop) {
		    $content .= "$pname=$val\n";
		}
	    } else {
		die "invalid property '$pname'\n";
	    }
	}
	$content .= "\n";
    }

    file_set_contents($filename, $content);
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', ['Sys.Audit', 'Datastore.Audit'], any => 1],
    },
    description => "PVE Managed Directory storages.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => {
		unitfile => {
		    type => 'string',
		    description => 'The path of the mount unit.',
		},
		path => {
		    type => 'string',
		    description => 'The mount path.',
		},
		device => {
		    type => 'string',
		    description => 'The mounted device.',
		},
		type => {
		    type => 'string',
		    description => 'The filesystem type.',
		},
		options => {
		    type => 'string',
		    description => 'The mount options.',
		},
	    },
	},
    },
    code => sub {
	my ($param) = @_;

	my $result = [];

	dir_glob_foreach('/etc/systemd/system', '^mnt-pve-(.+)\.mount$', sub {
	    my ($filename, $storid) = @_;
	    $storid = PVE::Systemd::unescape_unit($storid);

	    my $unitfile = "/etc/systemd/system/$filename";
	    my $unit = $read_ini->($unitfile);

	    push @$result, {
		unitfile => $unitfile,
		path => "/mnt/pve/$storid",
		device => $unit->{'Mount'}->{'What'},
		type => $unit->{'Mount'}->{'Type'},
		options => $unit->{'Mount'}->{'Options'},
	    };
	});

	return $result;
    }});

__PACKAGE__->register_method ({
    name => 'create',
    path => '',
    method => 'POST',
    proxyto => 'node',
    protected => 1,
    permissions => {
	check => ['perm', '/', ['Sys.Modify', 'Datastore.Allocate']],
    },
    description => "Create a Filesystem on an unused disk. Will be mounted under '/mnt/pve/NAME'.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    name => get_standard_option('pve-storage-id'),
	    device => {
		type => 'string',
		description => 'The block device you want to create the filesystem on.',
	    },
	    add_storage => {
		description => "Configure storage using the directory.",
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	    filesystem => {
		description => "The desired filesystem.",
		type => 'string',
		enum => ['ext4', 'xfs'],
		optional => 1,
		default => 'ext4',
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $user = $rpcenv->get_user();

	my $name = $param->{name};
	my $dev = $param->{device};
	my $node = $param->{node};
	my $type = $param->{filesystem} // 'ext4';

	$dev = PVE::Diskmanage::verify_blockdev_path($dev);
	PVE::Diskmanage::assert_disk_unused($dev);
	PVE::Storage::assert_sid_unused($name) if $param->{add_storage};

	my $worker = sub {
	    my $path = "/mnt/pve/$name";
	    my $mountunitname = PVE::Systemd::escape_unit($path, 1) . ".mount";
	    my $mountunitpath = "/etc/systemd/system/$mountunitname";

	    PVE::Diskmanage::locked_disk_action(sub {
		# create partition
		my $cmd = [$SGDISK, '-n1', '-t1:8300', $dev];
		print "# ", join(' ', @$cmd), "\n";
		run_command($cmd);

		my ($devname) = $dev =~ m|^/dev/(.*)$|;
		my $part = "/dev/";
		dir_glob_foreach("/sys/block/$devname", qr/\Q$devname\E.+/, sub {
		    my ($partition) = @_;
		    $part .= $partition;
		});

		# create filesystem
		$cmd = [$MKFS, '-t', $type, $part];
		print "# ", join(' ', @$cmd), "\n";
		run_command($cmd);

		# create systemd mount unit and enable & start it
		my $ini = {
		    'Unit' => {
			'Description' => "Mount storage '$name' under /mnt/pve",
		    },
		    'Install' => {
			'WantedBy' => 'multi-user.target',
		    },
		};

		my $uuid_path;
		my $uuid;

		$cmd = [$BLKID, $part, '-o', 'export'];
		print "# ", join(' ', @$cmd), "\n";
		run_command($cmd, outfunc => sub {
			my ($line) = @_;

			if ($line =~ m/^UUID=(.*)$/) {
			    $uuid = $1;
			    $uuid_path = "/dev/disk/by-uuid/$uuid";
			}
		    });

		die "could not get UUID of device '$part'\n" if !$uuid;

		$ini->{'Mount'} = {
		    'What' => $uuid_path,
		    'Where' => $path,
		    'Type' => $type,
		    'Options' => 'defaults',
		};

		$write_ini->($ini, $mountunitpath);

		run_command(['systemctl', 'daemon-reload']);
		run_command(['systemctl', 'enable', $mountunitname]);
		run_command(['systemctl', 'start', $mountunitname]);

		if ($param->{add_storage}) {
		    my $storage_params = {
			type => 'dir',
			storage => $name,
			content => 'rootdir,images,iso,backup,vztmpl,snippets',
			is_mountpoint => 1,
			path => $path,
			nodes => $node,
		    };

		    PVE::API2::Storage::Config->create($storage_params);
		}
	    });
	};

	return $rpcenv->fork_worker('dircreate', $name, $user, $worker);
    }});

1;
