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
my @FOLDER_PROPERTIES = ( 'name', 'parent', 'childEntity' );
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
my %inventory_structure = ( 'datastructure' => { 'version' => '0.1' , 'type' => 'vmware-datacenter-folder-export'} );

# cache managed object views to folders by moref->value (e.g. group-210 ).
my %cached_folder_views_by_moref;

sub get_folder_view_by_moref_value {
  my $moref = shift;
  my $result = $cached_folder_views_by_moref{$$moref{value}};
  unless (defined $result) {
    $result =  $vim->get_view( mo_ref => $moref,
                              properties => \@FOLDER_PROPERTIES
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
        properties   => \@FOLDER_PROPERTIES,
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
   
print STDERR "\nAcquiring vmFolders  for Datacenter '". $dc_name ."'... ";
my $dc_folder =  $vim->get_view(
    mo_ref => $datacenter_view->{vmFolder},
    properties => \@FOLDER_PROPERTIES
);  
$inventory_structure{'listOfVmFolders'} = get_foldernames($dc_folder);


print STDERR "\nAcquiring datastoreFolders for Datacenter '". $dc_name ."'... ";
$dc_folder =  $vim->get_view(
    mo_ref => $datacenter_view->{datastoreFolder},
    properties => \@FOLDER_PROPERTIES
);  
$inventory_structure{'listOfDatastoreFolders'} = get_foldernames($dc_folder);


print STDERR "\nAcquiring networkFolders for Datacenter '". $dc_name ."'... ";
$dc_folder =  $vim->get_view(
    mo_ref => $datacenter_view->{networkFolder},
    properties => \@FOLDER_PROPERTIES
);  
$inventory_structure{'listOfNetworkFolders'} = get_foldernames($dc_folder);


print STDERR "\nAcquiring hostFolders for Datacenter '". $dc_name ."'... ";
$dc_folder =  $vim->get_view(
    mo_ref => $datacenter_view->{hostFolder},
    properties => \@FOLDER_PROPERTIES
);  
$inventory_structure{'listOfHostFolders'} = get_foldernames($dc_folder);


    
print STDERR "\n YAML structure:\n";
print Dump( \%inventory_structure);
print "\n";

Util::disconnect();
