#!/usr/bin/env perl

=head1 NAME

exportFolders.pl

=head1 DESCRIPTION

Generates output with all vSphere folders in YAML format.
This can be used e.g. for an ansible playbook.
=head1 AUTHOR

2018 Tim Lapawa - <github@lapawa.de>

=cut

use strict;
use warnings;
use YAML;

use VMware::VIRuntime;
use VMware::VILib;
use VMware::VIExt;


my %opts = (
    datacenter => {
        type => "=s",
        required => 0,
        help => "Datacenter name. Select a single datacenter to process. Script picks the first if left empty.",
    },
);


# List of object properties to request vom vCenter Server
my @DVSWITCH_PROPERTIES  = ( 'name', 'portgroup' );
my @PORTGROUP_PROPERTIES = ( 'name', 'config.defaultPortConfig' );
# 'childEntity',
my @DATACENTER_PROPERTIES = ( 'name', 'datastoreFolder', 'networkFolder', 'hostFolder', 'vmFolder', );

Opts::add_options(%opts);
Opts::parse();
Opts::validate();
my $opt_datacenter = Opts::get_option('datacenter');

Util::connect();
my $vim = Vim::get_vim();
#$SIG{__DIE__} = sub{Util::disconnect();};


# Global datastructure to collect the objects to export 
my %inventory_structure = ( 'datastructure' => { 'version' => '0.1' , 'type' => 'vsphere-export-dvswitches-per-datacenter'} );

# cache managed object views to folders by moref->value (e.g. group-210 ).
my %cached_folder_views_by_moref;

sub get_folder_view_by_moref_value {
  my $moref = shift;
  my $result = $cached_folder_views_by_moref{$$moref{value}};
  unless (defined $result) {
    $result =  $vim->get_view( mo_ref => $moref,
#                              properties => \@FOLDER_PROPERTIES
    );
    $cached_folder_views_by_moref{$$moref{value}} = $result;
  }
  return $result;
} # get_folder_view_by_moref_value


sub get_foldernames {
    my $dc_folder = shift;
    my $root_folder_moref_value = $dc_folder->{mo_ref}->{value};
    
    my $folder_views =  $vim->find_entity_views(
        begin_entity => $dc_folder->{mo_ref},
        view_type    => 'Folder',
#        properties   => \@FOLDER_PROPERTIES,
    );
    
    my @folder_names;
    foreach my $folder_view (@$folder_views){
        next if ($folder_view->{mo_ref}->{value} eq $root_folder_moref_value);
    
        my $parent_folder_name = undef;
        my $parent_moref_value = $$folder_view{parent}->{value};
        if ( $parent_moref_value ne $root_folder_moref_value) {
            if ( $$folder_view{parent}->{type} ne 'Folder') {
                Carp::confess("mo_ref argument is invalid.");
            }
            my $folder = get_folder_view_by_moref_value( $$folder_view{parent} );
            $parent_folder_name = $$folder{name};
        }
        
        push @folder_names, {
                name => $$folder_view{name},
                parent_folder => $parent_folder_name
        };
    }
    return \@folder_names;
} # get_foldernames


sub get_dvswitch {
    my $dvswitch_view = shift;
    my %result = (
        'name' => $$dvswitch_view{name},
    );
    my @portgroups;

    my $pg_views = $vim->get_views(
        mo_ref_array => $$dvswitch_view{portgroup},
        properties   => \@PORTGROUP_PROPERTIES
    );

    foreach my $pg_view (@$pg_views) {
		next if( $$pg_view{'name'} =~ /Uplink/ );
#        next if (  $$pg_view{'config'}{'uplink'} eq 'yes');  # parameter is available with configVersion= 1
        push @portgroups, {
            'name' => $$pg_view{'name'},
            'VLAN' => $$pg_view{'config.defaultPortConfig'}->{'vlan'}->{'vlanId'}
        };
    }
    
    $result{portgroups} = \@portgroups;
    return \%result;
} # get_dvswitch


my $datacenter_view;
if (defined $opt_datacenter) {
  $datacenter_view = $vim->find_entity_view(
    view_type  => 'Datacenter',
    filter     => { 'name' => $opt_datacenter },
    properties => \@DATACENTER_PROPERTIES
  );
} else {
  my $views = $vim->find_entity_views(
      view_type  => 'Datacenter',
      properties => \@DATACENTER_PROPERTIES
  );
  $datacenter_view = pop @$views;  
}

unless (defined $datacenter_view) {
  print STDERR 'Failed to find datacenter. EXIT(1)';
  exit 1;
}

my $dc_name = $datacenter_view->{name};
$inventory_structure{datacenter} = $dc_name;
   
print STDERR "\nAcquiring dvSwitches for Datacenter '". $dc_name ."'... ";
my $dvswitches =  $vim->find_entity_views(
    begin_entity => $datacenter_view->{networkFolder},
    view_type => 'VmwareDistributedVirtualSwitch',
    properties => \@DVSWITCH_PROPERTIES
);

my @dvswitch_objects;
foreach my $dvswitch_view (@$dvswitches) {
    push @dvswitch_objects, get_dvswitch($dvswitch_view);
}
$inventory_structure{'listOfDvSwitches'} = \@dvswitch_objects;
    
print STDERR "\n YAML structure:\n";
print Dump( \%inventory_structure);
print "\n";

Util::disconnect();
