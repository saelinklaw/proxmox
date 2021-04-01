package PVE::API2::Storage::Config;

use strict;
use warnings;

use PVE::SafeSyslog;
use PVE::Tools qw(extract_param extract_sensitive_params);
use PVE::Cluster qw(cfs_read_file cfs_write_file);
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::Storage::LVMPlugin;
use PVE::Storage::CIFSPlugin;
use HTTP::Status qw(:constants);
use Storable qw(dclone);
use PVE::JSONSchema qw(get_standard_option);
use PVE::RPCEnvironment;

use PVE::RESTHandler;

use base qw(PVE::RESTHandler);

my @ctypes = qw(images vztmpl iso backup);

my $storage_type_enum = PVE::Storage::Plugin->lookup_types();

my $api_storage_config = sub {
    my ($cfg, $storeid) = @_;

    my $scfg = dclone(PVE::Storage::storage_config($cfg, $storeid));
    $scfg->{storage} = $storeid;
    $scfg->{digest} = $cfg->{digest};
    $scfg->{content} = PVE::Storage::Plugin->encode_value($scfg->{type}, 'content', $scfg->{content});

    if ($scfg->{nodes}) {
	$scfg->{nodes} = PVE::Storage::Plugin->encode_value($scfg->{type}, 'nodes', $scfg->{nodes});
    }

    return $scfg;
};

__PACKAGE__->register_method ({
    name => 'index',
    path => '',
    method => 'GET',
    description => "Storage index.",
    permissions => {
	description => "Only list entries where you have 'Datastore.Audit' or 'Datastore.AllocateSpace' permissions on '/storage/<storage>'",
	user => 'all',
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    type => {
		description => "Only list storage of specific type",
		type => 'string',
		enum => $storage_type_enum,
		optional => 1,
	    },
	},
    },
    returns => {
	type => 'array',
	items => {
	    type => "object",
	    properties => { storage => { type => 'string'} },
	},
	links => [ { rel => 'child', href => "{storage}" } ],
    },
    code => sub {
	my ($param) = @_;

	my $rpcenv = PVE::RPCEnvironment::get();
	my $authuser = $rpcenv->get_user();

	my $cfg = PVE::Storage::config();

	my @sids = PVE::Storage::storage_ids($cfg);

	my $res = [];
	foreach my $storeid (@sids) {
	    my $privs = [ 'Datastore.Audit', 'Datastore.AllocateSpace' ];
	    next if !$rpcenv->check_any($authuser, "/storage/$storeid", $privs, 1);

	    my $scfg = &$api_storage_config($cfg, $storeid);
	    next if $param->{type} && $param->{type} ne $scfg->{type};
	    push @$res, $scfg;
	}

	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'read',
    path => '{storage}',
    method => 'GET',
    description => "Read storage configuration.",
    permissions => {
	check => ['perm', '/storage/{storage}', ['Datastore.Allocate']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    storage => get_standard_option('pve-storage-id'),
	},
    },
    returns => { type => 'object' },
    code => sub {
	my ($param) = @_;

	my $cfg = PVE::Storage::config();

	return &$api_storage_config($cfg, $param->{storage});
    }});

my $sensitive_params = [qw(password encryption-key)];

__PACKAGE__->register_method ({
    name => 'create',
    protected => 1,
    path => '',
    method => 'POST',
    description => "Create a new storage.",
    permissions => {
	check => ['perm', '/storage', ['Datastore.Allocate']],
    },
    parameters => PVE::Storage::Plugin->createSchema(),
    returns => {
	type => 'object',
	properties => {
	    storage => {
		description => "The ID of the created storage.",
		type => 'string',
	    },
	    type => {
		description => "The type of the created storage.",
		type => 'string',
		enum => $storage_type_enum,
	    },
	    config => {
		description => "Partial, possible server generated, configuration properties.",
		type => 'object',
		optional => 1,
		additionalProperties => 1,
		properties => {
		    'encryption-key' => {
			description => "The, possible auto-generated, encryption-key.",
			optional => 1,
			type => 'string',
		    },
		},
	    },
	},
    },
    code => sub {
	my ($param) = @_;

	my $type = extract_param($param, 'type');
	my $storeid = extract_param($param, 'storage');

	# revent an empty nodelist.
	# fix me in section config create never need an empty entity.
	delete $param->{nodes} if !$param->{nodes};

	my $sensitive = extract_sensitive_params($param, $sensitive_params, []);

	my $plugin = PVE::Storage::Plugin->lookup($type);
	my $opts = $plugin->check_config($storeid, $param, 1, 1);

	my $returned_config;
	PVE::Storage::lock_storage_config(sub {
	    my $cfg = PVE::Storage::config();

	    if (my $scfg = PVE::Storage::storage_config($cfg, $storeid, 1)) {
		die "storage ID '$storeid' already defined\n";
	    }

	    $cfg->{ids}->{$storeid} = $opts;

	    $returned_config = $plugin->on_add_hook($storeid, $opts, %$sensitive);

	    eval {
		# try to activate if enabled on local node,
		# we only do this to detect errors/problems sooner
		if (PVE::Storage::storage_check_enabled($cfg, $storeid, undef, 1)) {
		    PVE::Storage::activate_storage($cfg, $storeid);
		}
	    };
	    if (my $err = $@) {
		eval { $plugin->on_delete_hook($storeid, $opts) };
		warn "$@\n" if $@;
		die $err;
	    }

	    PVE::Storage::write_config($cfg);

	}, "create storage failed");

	my $res = {
	    storage => $storeid,
	    type => $type,
	};
	$res->{config} = $returned_config if $returned_config;
	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'update',
    protected => 1,
    path => '{storage}',
    method => 'PUT',
    description => "Update storage configuration.",
    permissions => {
	check => ['perm', '/storage', ['Datastore.Allocate']],
    },
    parameters => PVE::Storage::Plugin->updateSchema(),
    returns => {
	type => 'object',
	properties => {
	    storage => {
		description => "The ID of the created storage.",
		type => 'string',
	    },
	    type => {
		description => "The type of the created storage.",
		type => 'string',
		enum => $storage_type_enum,
	    },
	    config => {
		description => "Partial, possible server generated, configuration properties.",
		type => 'object',
		optional => 1,
		additionalProperties => 1,
		properties => {
		    'encryption-key' => {
			description => "The, possible auto-generated, encryption-key.",
			optional => 1,
			type => 'string',
		    },
		},
	    },
	},
    },
    code => sub {
	my ($param) = @_;

	my $storeid = extract_param($param, 'storage');
	my $digest = extract_param($param, 'digest');
	my $delete = extract_param($param, 'delete');
	my $type;

	if ($delete) {
	    $delete = [ PVE::Tools::split_list($delete) ];
	}

	my $returned_config;
        PVE::Storage::lock_storage_config(sub {
	    my $cfg = PVE::Storage::config();

	    PVE::SectionConfig::assert_if_modified($cfg, $digest);

	    my $scfg = PVE::Storage::storage_config($cfg, $storeid);
	    $type = $scfg->{type};

	    my $sensitive = extract_sensitive_params($param, $sensitive_params, $delete);

	    my $plugin = PVE::Storage::Plugin->lookup($type);
	    my $opts = $plugin->check_config($storeid, $param, 0, 1);

	    if ($delete) {
		my $options = $plugin->private()->{options}->{$type};
		foreach my $k (@$delete) {
		    my $d = $options->{$k} || die "no such option '$k'\n";
		    die "unable to delete required option '$k'\n" if !$d->{optional};
		    die "unable to delete fixed option '$k'\n" if $d->{fixed};
		    die "cannot set and delete property '$k' at the same time!\n"
			if defined($opts->{$k});

		    delete $scfg->{$k};
		}
	    }

	    $returned_config = $plugin->on_update_hook($storeid, $opts, %$sensitive);

	    for my $k (keys %$opts) {
		$scfg->{$k} = $opts->{$k};
	    }

	    PVE::Storage::write_config($cfg);

	}, "update storage failed");

	my $res = {
	    storage => $storeid,
	    type => $type,
	};
	$res->{config} = $returned_config if $returned_config;
	return $res;
    }});

__PACKAGE__->register_method ({
    name => 'delete',
    protected => 1,
    path => '{storage}', # /storage/config/{storage}
    method => 'DELETE',
    description => "Delete storage configuration.",
    permissions => {
	check => ['perm', '/storage', ['Datastore.Allocate']],
    },
    parameters => {
	additionalProperties => 0,
	properties => {
	    storage => get_standard_option('pve-storage-id', {
		completion => \&PVE::Storage::complete_storage,
	    }),
	},
    },
    returns => { type => 'null' },
    code => sub {
	my ($param) = @_;

	my $storeid = extract_param($param, 'storage');

        PVE::Storage::lock_storage_config(sub {
	    my $cfg = PVE::Storage::config();

	    my $scfg = PVE::Storage::storage_config($cfg, $storeid);

	    die "can't remove storage - storage is used as base of another storage\n"
		if PVE::Storage::storage_is_used($cfg, $storeid);

	    my $plugin = PVE::Storage::Plugin->lookup($scfg->{type});

	    $plugin->on_delete_hook($storeid, $scfg);

	    delete $cfg->{ids}->{$storeid};

	    PVE::Storage::write_config($cfg);

	}, "delete storage failed");

	PVE::AccessControl::remove_storage_access($storeid);

	return undef;
    }});

1;
