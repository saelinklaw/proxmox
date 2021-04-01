package PVE::API2::Disks;

use strict;
use warnings;

use HTTP::Status qw(:constants);

use PVE::Diskmanage;
use PVE::JSONSchema qw(get_standard_option);
use PVE::SafeSyslog;

use PVE::API2::Disks::Directory;
use PVE::API2::Disks::LVM;
use PVE::API2::Disks::LVMThin;
use PVE::API2::Disks::ZFS;

use PVE::RESTHandler;
use base qw(PVE::RESTHandler);

__PACKAGE__->register_method ({
   subclass => "PVE::API2::Disks::LVM",
   path => 'lvm',
});

__PACKAGE__->register_method ({
   subclass => "PVE::API2::Disks::LVMThin",
   path => 'lvmthin',
});

__PACKAGE__->register_method ({
   subclass => "PVE::API2::Disks::Directory",
   path => 'directory',
});

__PACKAGE__->register_method ({
   subclass => "PVE::API2::Disks::ZFS",
   path => 'zfs',
});

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    proxyto => 'node',
    permissions => { user => 'all' },
    description => "Node index.",
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => {},
	},
	links => [ { rel => 'child', href => "{name}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $result = [
	    { name => 'list' },
	    { name => 'initgpt' },
	    { name => 'smart' },
	    { name => 'lvm' },
	    { name => 'lvmthin' },
	    { name => 'directory' },
	    { name => 'zfs' },
	];

	return $result;
    }});

__PACKAGE__->register_method ({
    name => 'list',
    path => 'list',
    method => 'GET',
    description => "List local disks.",
    protected => 1,
    proxyto => 'node',
    permissions => {
	check => ['or',
	    ['perm', '/', ['Sys.Audit', 'Datastore.Audit'], any => 1],
	    ['perm', '/nodes/{node}', ['Sys.Audit', 'Datastore.Audit'], any => 1],
	],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    'include-partitions' => {
		description => "Also include partitions.",
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	    skipsmart => {
		description => "Skip smart checks.",
		type => 'boolean',
		optional => 1,
		default => 0,
	    },
	    type => {
		description => "Only list specific types of disks.",
		type => 'string',
		enum => ['unused', 'journal_disks'],
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => 'object',
	    properties => {
		devpath => {
		    type => 'string',
		    description => 'The device path',
		},
		used => { type => 'string', optional => 1 },
		gpt => { type => 'boolean' },
		size => { type => 'integer'},
		osdid => { type => 'integer'},
		vendor =>  { type => 'string', optional => 1 },
		model =>  { type => 'string', optional => 1 },
		serial =>  { type => 'string', optional => 1 },
		wwn => { type => 'string', optional => 1},
		health => { type => 'string', optional => 1},
		parent => {
		    type => 'string',
		    description => 'For partitions only. The device path of ' .
			'the disk the partition resides on.',
		    optional => 1
		},
	    },
	},
    },
    code => sub {
	my ($param) = @_;

	my $skipsmart = $param->{skipsmart} // 0;
	my $include_partitions = $param->{'include-partitions'} // 0;

	my $disks = PVE::Diskmanage::get_disks(
	    undef,
	    $skipsmart,
	    $include_partitions
	);

	my $type = $param->{type} // '';
	my $result = [];

	foreach my $disk (sort keys %$disks) {
	    my $entry = $disks->{$disk};
	    if ($type eq 'journal_disks') {
		next if $entry->{osdid} >= 0;
		if (my $usage = $entry->{used}) {
		    next if !($usage eq 'partitions' && $entry->{gpt}
			|| $usage eq 'LVM');
		}
	    } elsif ($type eq 'unused') {
		next if $entry->{used};
	    } elsif ($type ne '') {
		die "internal error"; # should not happen
	    }
	    push @$result, $entry;
	}
	return $result;
    }});

__PACKAGE__->register_method ({
    name => 'smart',
    path => 'smart',
    method => 'GET',
    description => "Get SMART Health of a disk.",
    protected => 1,
    proxyto => "node",
    permissions => {
	check => ['perm', '/', ['Sys.Audit', 'Datastore.Audit'], any => 1],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    disk => {
		type => 'string',
		pattern => '^/dev/[a-zA-Z0-9\/]+$',
		description => "Block device name",
	    },
	    healthonly => {
		type => 'boolean',
		description => "If true returns only the health status",
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'object',
	properties => {
	    health => { type => 'string' },
	    type => { type => 'string', optional => 1 },
	    attributes => { type => 'array', optional => 1},
	    text => { type => 'string', optional => 1 },
	},
    },
    code => sub {
	my ($param) = @_;

	my $disk = PVE::Diskmanage::verify_blockdev_path($param->{disk});

	my $result = PVE::Diskmanage::get_smart_data($disk, $param->{healthonly});

	$result->{health} = 'UNKNOWN' if !defined $result->{health};
	$result = { health => $result->{health} } if $param->{healthonly};

	return $result;
    }});

__PACKAGE__->register_method ({
    name => 'initgpt',
    path => 'initgpt',
    method => 'POST',
    description => "Initialize Disk with GPT",
    protected => 1,
    proxyto => "node",
    permissions => {
	check => ['perm', '/', ['Sys.Modify']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    node => get_standard_option('pve-node'),
	    disk => {
		type => 'string',
		description => "Block device name",
		pattern => '^/dev/[a-zA-Z0-9\/]+$',
	    },
	    uuid => {
		type => 'string',
		description => 'UUID for the GPT table',
		pattern => '[a-fA-F0-9\-]+',
		maxLength => 36,
		optional => 1,
	    },
	},
    },
    returns => { type => 'string' },
    code => sub {
	my ($param) = @_;

	my $disk = PVE::Diskmanage::verify_blockdev_path($param->{disk});

	my $rpcenv = PVE::RPCEnvironment::get();

	my $authuser = $rpcenv->get_user();

	die "disk $disk already in use\n" if PVE::Diskmanage::disk_is_used($disk);
	my $worker = sub {
	    PVE::Diskmanage::init_disk($disk, $param->{uuid});
	};

	my $diskid = $disk;
	$diskid =~ s|^.*/||; # remove all up to the last slash
	return $rpcenv->fork_worker('diskinit', $diskid, $authuser, $worker);
    }});

1;
