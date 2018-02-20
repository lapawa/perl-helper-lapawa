#!/usr/bin/env perl


=head1 NAME

exportVirtualMachineInfos.pl

=head1 DESCRIPTION

Iterate over all Virtual Machines in a vCenter Server or Datacenter element and print several information about them in JSON format.
--operation export 
  - Name of Virtual Machine
  - Virtual Machine Folder
  
--operation movevms
Picks the JSON file from 'export' and moves virtual machines to existing folders.

=head1 AUTHOR

2018 Tim Lapawa - <github@lapawa.de>

=cut

use strict;
use warnings;
use JSON;

use VMware::VIRuntime;
use VMware::VILib;
use VMware::VIExt;

my %opts = (
    inventoryfile => {
        type     => "=s",
        help     => "JSON file with inventory export. Used by operation movevms",
        required => 0,
    },
    operation => {
        type => "=s",
        help => "Operation can be one of 'export' or 'movevms'. Defaults is export.",
        required => 0,
    },
	datacenter => {
		type => "=s",
		required => 0,
		help => "Datacenter name. Select a single datacenter to process.",
	},
);

# List of object properties to request vom vCenter Server
my @VIRTUALMACHINE_PROPERTIES = ( 'name', 'config.uuid' );
my @FOLDER_PROPERTIES = ( 'name', 'childEntity' );
my @DATACENTER_PROPERTIES = ( 'name','vmFolder' );

Opts::add_options(%opts);
Opts::parse();
Opts::validate();
my $operation          = Opts::get_option('operation');
my $inventory_filename = Opts::get_option('inventoryfile');
my $opt_datacenter     = Opts::get_option('datacenter');

# Check combination of options:
if (!defined $operation or lc $operation eq 'export') {
    $operation = 'export'
} elsif (lc $operation eq 'movevms' ){
    $operation = lc $operation;
    Opts::assert_usage( defined $inventory_filename ,"Operation 'movevms' expects option '--inventoryfile <file>'." );
} else {
    Opts::usage();
    exit 1;
}


Util::connect();
$SIG{__DIE__} = sub{Util::disconnect();};


my %inventory_structure = ( 'datastructure' => { 'version' => '0.1' , 'type' => 'vmware-vcenter-inventory-export'} );

sub
get_vm_views {
    my $refs = shift;
    
    return Vim::get_views(
        mo_ref_array => $refs,
        properties   => \@VIRTUALMACHINE_PROPERTIES,
    );
} # get_vm_views


# cache managed object views to virtual machins by key uuid.
my %cached_vm_views_by_uuid;

sub find_vm_view_by_uuid{
    my $begin_entity = shift;
    my $uuid_ = shift;
    my $result;
    # Cache hit?
    if (exists $cached_vm_views_by_uuid{$uuid_} ) {
        $result =$cached_vm_views_by_uuid{$uuid_};
    } else {
        $result = Vim::find_entity_view(
            begin_entity => $begin_entity,
            filter       => { 'config.uuid' => $uuid_ },
            view_type    => 'VirtualMachine',
            properties   => \@VIRTUALMACHINE_PROPERTIES,
        );

        if (defined $result ) {
            $cached_vm_views_by_uuid{$uuid_} = $result;
        } else {
            print "vCenter does not know a virtual machine with uuid(".$uuid_.").";
        }
    }
    return $result;
} # get_vm_view_by_uuid


sub
get_folder_views {
    my $refs = shift;
    
    return Vim::get_views(
        mo_ref_array => $refs,
        properties   => \@FOLDER_PROPERTIES,
    );
} # get_folder_views

sub
traverse_folder {
    my $folder_view  = shift;
    
    my %structure = (
        'type' => $folder_view->{mo_ref}->{type},
        'name' => $folder_view->{name}
        );

#    print STDERR 'Traversing: '.$folder_stack."\n";
    
    my @vm_refs;
    my @folder_refs;
        # Sort the child elements by type
        my $mo_refs = $folder_view->{childEntity};
        foreach my $mo_ref (@$mo_refs){
            if ($mo_ref->{type} eq 'VirtualMachine') {
                push @vm_refs, $mo_ref;
            } elsif ($mo_ref->{type} eq 'Folder' ) {
                push @folder_refs, $mo_ref;
            } else {
                print STDERR "\nFound unhandled managed object type: '". $mo_ref->{type} ."'. SKIPPING!";
            }
        }

        if (my $vms = extract_virtual_machines(\@vm_refs)) {
            $structure{'vms'} = $vms;
        }
        
        if (scalar @folder_refs) {
            my $folder_views = get_folder_views(\@folder_refs);
            if ($folder_views) {
                my @folders = ();
                foreach my $folder_view (@$folder_views){
                    my $subfolder = traverse_folder($folder_view);
                    push @folders, $subfolder;
                }
                $structure{'vmFolder'} = \@folders;
            }
        }

    return \%structure;
} # traverse_folder



sub
extract_virtual_machines {
    my $vm_refs = shift;
    if ($vm_refs && scalar @$vm_refs) {
        my $vm_views = get_vm_views($vm_refs);
        if ($vm_views) {
            my @vms;
            foreach my $vm_view (@$vm_views){
                push @vms, {
                    'type' => 'VirtualMachine',
                    'name' => $vm_view->{'name'},
                    'uuid' => $vm_view->{'config.uuid'},
                };
            }
            return \@vms;
        } else {
            print STDERR "\nFailed to receive virtual machine views. SKIPPING!";
        }
    }
    return undef;
}  # extract_virtual_machines

sub
load_inventoryfile {
    my $filename = shift;
    my $errmsg;
    my $loaded_inventory;
    local $/;
    unless ( open(my $fh, "<", $filename)) { 
        print STDERR "\nFailed to load inventory file '".$filename."': $!.";
        return undef;
    } else {
        my $raw_data = <$fh>;
        eval {
            $loaded_inventory = JSON::decode_json($raw_data);
        };
        if( $@ )  {
            $errmsg = $@;
            close($fh);
            goto FAILED;
        }
        close($fh);
    }

    # Verify structure of loaded objects
    my $ds = exists $$loaded_inventory{'datastructure'}?$$loaded_inventory{'datastructure'}:undef;
    unless (defined $ds){ $errmsg = "Missing object 'datastructure'"; goto FAILED;}
    my $type = exists $$ds{'type'}? $$ds{'type'}: undef;
    unless (defined $type){ $errmsg = "Missing property 'datastructure[type]'"; goto FAILED;}
    my $version = exists $$ds{'version'}? $$ds{'version'}: undef;
    unless( $version ) { $errmsg = "Missing property 'datastructure[version]'"; goto FAILED;}
    
    unless ( $type eq 'vmware-vcenter-inventory-export') {
        $errmsg = "Expecting datastructure[type] == 'vmware-vcenter-inventory-export'. But received '".$type."'";
        goto FAILED;
    }
    unless ( $version eq '0.1') {
        $errmsg = "Expecting datastructure[version] == '0.1'. But received '".$version."'";
        goto FAILED;
    }
    unless ( exists $$loaded_inventory{'datacenters'}){ $errmsg = "Expecting array datacenters"; goto FAILED;}

    return $loaded_inventory;

FAILED:
    print STDERR "\nFound malformed JSON datastructure in file '".$filename."': ".$errmsg;
    return undef;
}  # load_inventory



sub
traverse_snapshot_vm_folder{
    my $datacenter_ = shift;
    my $snapshot_   = shift;
    my $mo_view_    = shift;

    my $type = $$snapshot_{'type'};
    my $name = $$snapshot_{'name'};
    unless (defined $mo_view_ && $mo_view_->isa($$snapshot_{type})) {
        print STDERR "Traversal error. Type of inventory snapshot (".$type.") mismatches to type of managed object view (".ref($mo_view_).").";
        return undef;
    }
    
    unless ( $$mo_view_{name} eq $name ) {
        print STDERR "Traversal error. Name of inventory snapshot element (".$name.") mismatches the name of managed object view (".$$mo_view_{'name'}.").";
        return undef;
    }
    
    print "\nWorking on ".$type." '".$$snapshot_{name}."':";

    if ( $type eq 'Datacenter' ) {
        my $view = Vim::get_view( mo_ref => $$mo_view_{vmFolder}, properties => \@FOLDER_PROPERTIES);
        traverse_snapshot_vm_folder( $datacenter_, $$snapshot_{'vmFolder'}, $view );
    } elsif ( $type eq 'Folder') {
        
        # Sort childEntities by Type ( VirtualMachien and Folder )
        my @folder_morefs;
        my @vm_morefs;
        foreach my $moref (@{$$mo_view_{'childEntity'}}){
            if ($$moref{'type'} eq 'VirtualMachine') {
                push @vm_morefs, $moref;
            } else {
                push @folder_morefs, $moref;
            }
        }

        my $views = Vim::get_views(
                    mo_ref_array => \@vm_morefs,
                    view_type    => 'VirtualMachine' ,
                    properties   => \@VIRTUALMACHINE_PROPERTIES
        );
        my %folder_vm_views_by_uuid;
        foreach my $vm_view (@$views) {
            $folder_vm_views_by_uuid{$$vm_view{'config.uuid'}} = $vm_view;
            $cached_vm_views_by_uuid{$$vm_view{'config.uuid'}} = $vm_view unless exists $cached_vm_views_by_uuid{$$vm_view{'config.uuid'}};
        }
        $views = undef;

        # Handle Virtual machines
        if ( exists $$snapshot_{vms}) {

            my @move_these_virtual_machines_morefs;
            print "\n\tExpecting #". scalar @{$$snapshot_{'vms'}} ." virtual machines...";
            foreach my $snap_vm (@{$$snapshot_{'vms'}}) {
                my $uuid = $$snap_vm{'uuid'};
    
                unless ( exists $folder_vm_views_by_uuid{$uuid}) {
                    print "\n\tMissing vm(".$$snap_vm{'name'}."). Searching by uuid(".$uuid.")...";
    
                    # find in folder missing virtual machine
                    my $vm_view = find_vm_view_by_uuid($datacenter_, $uuid);
                    if (defined $vm_view) {
                        #my $vm_folder = Util::get_inventory_path($vm_view, $$mo_view_{'vim'} );
                        print " found it";# folder(".$vm_folder.").";
                        push @move_these_virtual_machines_morefs, $$vm_view{'mo_ref'};
                    }
                }
            }
    
            if (scalar @move_these_virtual_machines_morefs) {
                print "\n\tInitiating move of #".scalar @move_these_virtual_machines_morefs." missing virtual machine(s) back to folder(".$name.")...";
                $mo_view_->MoveIntoFolder( list => \@move_these_virtual_machines_morefs );
                print "done";
            } else {
                print " found all of them. Nothing to move. Good!";
            }
        } # if snapshot section 'vms' exists
        
        if ( exists $$snapshot_{'vmFolder'}) {
            
            # Get views of all sub folders:
            $views = Vim::get_views(
                        mo_ref_array => \@folder_morefs,
                        view_type    => 'Folder',
                        properties   => \@FOLDER_PROPERTIES,
            );
            # sort them by name
            my %subfolder_views_by_name;
            foreach my $view (@$views){
                $subfolder_views_by_name{$$view{'name'}} = $view;
            }
            $views = undef;
            
            # Handle the folders:
            foreach my $snap_folder (@{$$snapshot_{'vmFolder'}}){
                # Search matching folder in views
                if ( exists $subfolder_views_by_name{$$snap_folder{'name'}}) {
                    traverse_snapshot_vm_folder( $datacenter_, $snap_folder, $subfolder_views_by_name{$$snap_folder{'name'}} );
                } else {
                    # TODO: Create missing folder. Wait for vCenter and traverse into it
                    print STDERR "\nMissing folder(".$$snap_folder{'name'}."). Please create manually. SKIPPING!";
                }
            }
        } # if snapshot{vmFolder} exists 
    } # if mo_view type eq 'Folder'
} # traverse_snapshot_vm_folder


if($operation eq 'export'){
    
    my $datacenter_views;
    if ( defined $opt_datacenter ) {
        $datacenter_views = Vim::find_entity_views(
            view_type  => 'Datacenter',
            filter => { 'name' => $opt_datacenter },
            properties => [ 'name', 'vmFolder'],
        );
    } else {
        $datacenter_views = Vim::find_entity_views(
            view_type  => 'Datacenter',
            properties => [ 'name', 'vmFolder']
        );        
    }
    
    my @datacenters = ();
    foreach my $datacenter_view (@$datacenter_views){
        my $dc_name = $datacenter_view->{name};  
        print STDERR "\nAcquiring inventory for Datacenter '". $dc_name ."'... ";
        my $folder_view = Vim::get_view( mo_ref => $$datacenter_view{'vmFolder'}, properties => \@FOLDER_PROPERTIES);   
        my $dc_structure = traverse_folder($folder_view);
    
        push @datacenters, {
                'type'     => $datacenter_view->{mo_ref}->{type},
                'name'     => $dc_name,
                'vmFolder' => $dc_structure
        };
        print STDERR "done.";
    }
    
    $inventory_structure{datacenters} = \@datacenters;
    
    print STDERR "\n JSON structure:\n";
    my $json = encode_json \%inventory_structure;
    print $json;
    print "\n";
} elsif ( $operation eq 'movevms') {
    my $inventory_snapshot = load_inventoryfile($inventory_filename);  
    unless (defined $inventory_snapshot ){ print STDERR " EXIT(2)\n"; exit 2 }
    
    my $datacenters = $$inventory_snapshot{'datacenters'};
    foreach my $dc_snapshot (@$datacenters){
        my $dc_name = $$dc_snapshot{name};
        
        # Find datacenter selected by command line option
        if ( defined $opt_datacenter && !($dc_name eq $opt_datacenter)) {
            next;
        }
        
        my $dc_view = Vim::find_entity_view(
            view_type  => 'Datacenter',
            filter     => { 'name'=> $dc_name },
            properties => \@DATACENTER_PROPERTIES,
        );

        unless (defined $dc_view){
            print STDERR "Failed to find datacenter '".$dc_name."'. SKIPPING!";
            next;
        }

        traverse_snapshot_vm_folder($dc_view, $dc_snapshot, $dc_view);
        print " done\n";
    }
} # operation eq 'movevms'

Util::disconnect();
