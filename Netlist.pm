# Verilog - Verilog Perl Interface
# See copyright, etc in below POD section.
######################################################################

package Verilog::Netlist;
use Carp;
use IO::File;

use Verilog::Netlist::File;
use Verilog::Netlist::Interface;
use Verilog::Netlist::Module;
use Verilog::Netlist::Subclass;
use base qw(Verilog::Netlist::Subclass);
use strict;
use vars qw($Debug $Verbose $VERSION);

$VERSION = '3.427';

######################################################################
#### Error Handling

# Netlist file & line numbers don't apply
sub logger { return $_[0]->{logger}; }
sub filename { return 'Verilog::Netlist'; }
sub lineno { return ''; }

######################################################################
#### Creation

sub new {
    my $class = shift;
    my $self = {_interfaces => {},
		_modules => {},
		_files => {},
		implicit_wires_ok => 1,
		link_read => 1,
		logger => Verilog::Netlist::Logger->new,
		options => undef,	# Usually pointer to Verilog::Getopt
		symbol_table => [],	# Symbol table for Verilog::Parser
 		preproc => 'Verilog::Preproc',
		parser => 'Verilog::Netlist::File::Parser',
		remove_defines_without_tick => 0,   # Overriden in SystemC::Netlist
		#include_open_nonfatal => 0,
		#keep_comments => 0,
		#synthesis => 0,
		#use_pinselects => 0,
		use_vars => 1,
		_libraries_done => {},
		_need_link => [],	# Objects we need to ->link
		@_};
    bless $self, $class;
    return $self;
}

sub delete {
    my $self = shift;
    # Break circular references to netlist
    foreach my $subref ($self->modules) { $subref->delete; }
    foreach my $subref ($self->interfaces) { $subref->delete; }
    foreach my $subref ($self->files) { $subref->delete; }
    $self->{_modules} = {};
    $self->{_interfaces} = {};
    $self->{_files} = {};
    $self->{_need_link} = {};
}

######################################################################
#### Functions

sub link {
    my $self = shift;
    while (defined(my $subref = pop @{$self->{_need_link}})) {
	$subref->link();
    }
    # The above should have gotten everything, but a child class
    # may rely on old behavior or have added classes outside our
    # universe, so be nice and do it the old way too.
    $self->{_relink} = 1;
    while ($self->{_relink}) {
	$self->{_relink} = 0;
	foreach my $subref ($self->modules) {
	    $subref->link();
	}
	foreach my $subref ($self->interfaces) {
	    $subref->link();
	}
	foreach my $subref ($self->files) {
	    $subref->_link();
	}
    }
}

sub lint {
    my $self = shift;
    foreach my $subref ($self->modules_sorted) {
	next if $subref->is_libcell();
	$subref->lint();
    }
    foreach my $subref ($self->interfaces_sorted) {
	$subref->link();
    }
}

sub verilog_text {
    my $self = shift;
    my @out;
    foreach my $subref ($self->interfaces_sorted) {
	push @out, $subref->verilog_text, "\n";
    }
    foreach my $subref ($self->modules_sorted) {
	push @out, $subref->verilog_text, "\n";
    }
    return (wantarray ? @out : join('',@out));
}

sub dump {
    my $self = shift;
    foreach my $subref ($self->interfaces_sorted) {
	$subref->dump();
    }
    foreach my $subref ($self->modules_sorted) {
	$subref->dump();
    }
}

######################################################################
#### Module access

sub new_module {
    my $self = shift;
    # @_ params
    # Can't have 'new Verilog::Netlist::Module' do this,
    # as not allowed to override Class::Struct's new()
    my $modref = new Verilog::Netlist::Module
	(netlist=>$self,
	 keyword=>'module',
	 is_top=>1,
	 @_);
    $self->{_modules}{$modref->name} = $modref;
    push @{$self->{_need_link}}, $modref;
    return $modref;
}

sub new_root_module {
    my $self = shift;
    $self->{_modules}{'$root'} ||=
	$self->new_module(keyword=>'root_module',
			  name=>'$root',
			  @_);
    return $self->{_modules}{'$root'};
}

sub defvalue_nowarn {
    my $self = shift;
    my $sym = shift;
    # Look up the value of a define, letting the user pick the accessor class
    if (my $opt=$self->{options}) {
	return $opt->defvalue_nowarn($sym);
    }
    return undef;
}

sub remove_defines {
    my $self = shift;
    my $sym = shift;
    # This function is HOT
    my $xsym = $sym;
    # We only remove defines one level deep, for historical reasons.
    # We optionally don't require a ` as SystemC also uses this function and doesn't use `.
    if ($self->{remove_defines_without_tick} || $xsym =~ /^\`/) {
	$xsym =~ s/^\`//;
	my $val = $self->defvalue_nowarn($xsym);  #Undef if not found
	return $val if defined $val;
    }
    return $sym;
}

sub find_module_or_interface_for_cell {
    # ($self,$name)   Are arguments, hardcoded below
    # Hot function, used only by Verilog::Netlist::Cell linking
    # Doesn't need to remove defines, as that's already done by caller
    return $_[0]->{_modules}{$_[1]} || $_[0]->{_interfaces}{$_[1]};
}

sub find_module {
    my $self = shift;
    my $search = shift;
    # Return module maching name
    my $mod = $self->{_modules}{$search};
    return $mod if $mod;
    # Allow FOO_CELL to be a #define to choose what instantiation is really used
    my $rsearch = $self->remove_defines($search);
    if ($rsearch ne $search) {
	return $self->find_module($rsearch);
    }
    return undef;
}

sub modules {
    my $self = shift;
    # Return all modules
    return (values %{$self->{_modules}});
}

sub modules_sorted {
    my $self = shift;
    # Return all modules
    return (sort {$a->name cmp $b->name} (values %{$self->{_modules}}));
}

sub modules_sorted_level {
    my $self = shift;
    # Return all modules
    return (sort {$a->level <=> $b->level || $a->name cmp $b->name}
	    (values %{$self->{_modules}}));
}

sub top_modules_sorted {
    my $self = shift;
    return grep ($_->is_top && !$_->is_libcell, $self->modules_sorted);
}

######################################################################
#### Interface access

sub new_interface {
    my $self = shift;
    # @_ params
    # Can't have 'new Verilog::Netlist::Interface' do this,
    # as not allowed to override Class::Struct's new()
    my $modref = new Verilog::Netlist::Interface
	(netlist=>$self,
	 @_);
    $self->{_interfaces}{$modref->name} = $modref;
    push @{$self->{_need_link}}, $modref;
    return $modref;
}

sub find_interface {
    my $self = shift;
    my $search = shift;
    # Return interface maching name
    my $mod = $self->{_interfaces}{$search};
    return $mod if $mod;
    # Allow FOO_CELL to be a #define to choose what instantiation is really used
    my $rsearch = $self->remove_defines($search);
    if ($rsearch ne $search) {
	return $self->find_interface($rsearch);
    }
    return undef;
}

sub interfaces {
    my $self = shift;
    # Return all interfaces
    return (values %{$self->{_interfaces}});
}

sub interfaces_sorted {
    my $self = shift;
    # Return all interfaces
    return (sort {$a->name cmp $b->name} (values %{$self->{_interfaces}}));
}

######################################################################
#### Files access

sub resolve_filename {
    my $self = shift;
    my $filename = shift;
    my $lookup_type = shift;
    if ($self->{options}) {
	$filename = $self->remove_defines($filename);
	$filename = $self->{options}->file_path($filename, $lookup_type);
    }
    if (!-r $filename || -d $filename) {
	return undef;
    }
    $self->dependency_in ($filename);
    return $filename;
}

sub new_file {
    my $self = shift;
    # @_ params
    # Can't have 'new Verilog::Netlist::File' do this,
    # as not allowed to override Class::Struct's new()
    my $fileref = new Verilog::Netlist::File
	(netlist=>$self,
	 @_);
    defined $fileref->name or carp "%Error: No name=> specified, stopped";
    $self->{_files}{$fileref->name} = $fileref;
    $fileref->basename (Verilog::Netlist::Module::modulename_from_filename($fileref->name));
    push @{$self->{_need_link}}, $fileref;
    return $fileref;
}

sub find_file {
    my $self = shift;
    my $search = shift;
    # Return file maching name
    return $self->{_files}{$search};
}

sub files {
    my $self = shift; ref $self or die;
    # Return all files
    return (sort {$a->name() cmp $b->name()} (values %{$self->{_files}}));
}
sub files_sorted { return files(@_); }

sub read_file {
    my $self = shift;
    my $fileref = $self->read_verilog_file(@_);
    return $fileref;
}

sub read_verilog_file {
    my $self = shift;
    my $fileref = Verilog::Netlist::File::read
	(netlist=>$self,
	 @_);
    return $fileref;
}

sub read_libraries {
    my $self = shift;
    if ($self->{options}) {
	my @files = $self->{options}->library();
	foreach my $file (@files) {
	    if (!$self->{_libraries_done}{$file}) {
		$self->{_libraries_done}{$file} = 1;
		$self->read_file(filename=>$file, is_libcell=>1, );
		## $self->dump();
	    }
	}
    }
}

######################################################################
#### Dependencies

sub dependency_in {
    my $self = shift;
    my $filename = shift;
    $self->{_depend_in}{$filename} = 1;
}
sub dependency_out {
    my $self = shift;
    my $filename = shift;
    $self->{_depend_out}{$filename} = 1;
}

sub dependency_write {
    my $self = shift;
    my $filename = shift;

    my $fh = IO::File->new(">$filename") or die "%Error: $! writing $filename\n";
    print $fh "$filename";
    foreach my $dout (sort (keys %{$self->{_depend_out}})) {
	print $fh " $dout";
    }
    print $fh " :";
    foreach my $din (sort (keys %{$self->{_depend_in}})) {
	print $fh " $din";
    }
    print $fh "\n";
    $fh->close();
}

######################################################################
#### Package return
1;
__END__

=pod

=head1 NAME

Verilog::Netlist - Verilog Netlist

=head1 SYNOPSIS

    use Verilog::Netlist;

    # Setup options so files can be found
    use Verilog::Getopt;
    my $opt = new Verilog::Getopt;
    $opt->parameter( "+incdir+verilog",
		     "-y","verilog",
		     );

    # Prepare netlist
    my $nl = new Verilog::Netlist (options => $opt,);
    foreach my $file ('testnetlist.v') {
	$nl->read_file (filename=>$file);
    }
    # Read in any sub-modules
    $nl->link();
    #$nl->lint();  # Optional, see docs; probably not wanted
    $nl->exit_if_error();

    foreach my $mod ($nl->top_modules_sorted) {
	show_hier ($mod, "  ", "", "");
    }

    sub show_hier {
	my $mod = shift;
	my $indent = shift;
	my $hier = shift;
	my $cellname = shift;
	if (!$cellname) {$hier = $mod->name;} #top modules get the design name
	else {$hier .= ".$cellname";} #append the cellname
	printf ("%-45s %s\n", $indent."Module ".$mod->name,$hier);
	foreach my $sig ($mod->ports_sorted) {
	    printf ($indent."	  %sput %s\n", $sig->direction, $sig->name);
	}
	foreach my $cell ($mod->cells_sorted) {
	    printf ($indent. "    Cell %s\n", $cell->name);
	    foreach my $pin ($cell->pins_sorted) {
		printf ($indent."     .%s(%s)\n", $pin->name, $pin->netname);
	    }
	    show_hier ($cell->submod, $indent."	 ", $hier, $cell->name) if $cell->submod;
	}
    }

=head1 DESCRIPTION

Verilog::Netlist reads and holds interconnect information about a whole
design database.

See the "Which Package" section of L<Verilog::Language> if you are unsure
which parsing package to use for a new application.

A Verilog::Netlist is composed of files, which contain the text read from
each file.

A file may contain modules, which are individual blocks that can be
instantiated (designs, in Synopsys terminology.)

Modules have ports, which are the interconnection between nets in that
module and the outside world.  Modules also have nets, (aka signals), which
interconnect the logic inside that module.

Modules can also instantiate other modules.  The instantiation of a module
is a Cell.  Cells have pins that interconnect the referenced module's pin
to a net in the module doing the instantiation.

Each of these types, files, modules, ports, nets, cells and pins have a
class.  For example Verilog::Netlist::Cell has the list of
Verilog::Netlist::Pin (s) that interconnect that cell.

=head1 FUNCTIONS

See also Verilog::Netlist::Subclass for additional accessors and methods.

=over 4

=item $netlist->lint

Error checks the entire netlist structure.  Currently there are only two
checks, that modules are bound to instantiations (which is also checked by
$netlist->link), and that signals aren't multiply driven.  Note that as
there is no elaboration you may get false errors about multiple drivers
from generate statements that are mutually exclusive.  For this reason and
the few lint checks you may not want to use this method.  Alternatively to
avoid pin interconnect checks, set the $netlist->new
(...use_vars=>0...) option.

=item $netlist->link()

Resolves references between the different modules.

If link_read=>1 is passed when netlist->new is called (it is by default),
undefined modules will be searched for using the Verilog::Getopt package,
passed by a reference in the creation of the netlist.  To suppress errors
in any missing references, set link_read_nonfatal=>1 also.

=item $netlist->new

Creates a new netlist structure.  Pass optional parameters by name,
with the following parameters:

=over 8

=item implicit_wires_ok => $true_or_false

Indicates whether to allow undeclared wires to be used.

=item include_open_nonfatal => $true_or_false

Indicates that include files that do not exist should be ignored.

=item keep_comments => $true_or_false

Indicates that comment fields should be preserved and on net declarations
into the Vtest::Netlist::Net structures.  Otherwise all comments are
stripped for speed.

=item link_read => $true_or_false

Indicates whether or not the parser should automatically search for
undefined modules through the "options" object.

=item link_read_nonfatal => $true_or_false

Indicates that modules that referenced but not found should be ignored,
rather than causing an error message.

=item logger => object

Specify a message handler object to be used for error handling, this class
should be a Verilog::Netlist::Logger object, or derived from one.  If
unspecified, a Verilog::Netlist::Logger local to this netlist will be
used.

=item options => $opt_object

An optional pointer to a Verilog::Getopt object, to be used for locating
files.

=item parser => $package_name

The name of the parser class. Defaults to "Verilog::Netlist::File::Parser".

=item preproc => $package_name

The name of the preprocessor class. Defaults to "Verilog::Preproc".

=item synthesis => $true_or_false

With synthesis set, define SYNTHESIS, and ignore text bewteen "ambit",
"pragma", "synopsys" or "synthesis" translate_off and translate_on meta
comments.  Note using metacomments is discouraged as they have led to
silicon bugs (versus ifdef SYNTHESIS); see
L<http://www.veripool.org/papers/TenIPEdits_SNUGBos07_paper.pdf>.

=item use_pinselects => $true_or_false

Indicates that bit selects should be parsed and intpreted.  False for
backward compatibility, but true recommended in new applications.

=item use_vars => $true_or_false

Indicates that signals, variables, and pin interconnect information is
needed; set by default.  If clear do not read it, nor report lint related
pin warnings, which can greatly improve performance.

=back

=item $netlist->dump

Prints debugging information for the entire netlist structure.

=back

=head1 INTERFACE FUNCTIONS

=over 4

=item $netlist->find_interface($name)

Returns Verilog::Netlist::Interface matching given name.

=item $netlist->interfaces

Returns list of Verilog::Netlist::Interface.

=item $netlist->interfaces_sorted

Returns name sorted list of Verilog::Netlist::Interface.

=item $netlist->new_interface

Creates a new Verilog::Netlist::Interface.

=back

=head1 MODULE FUNCTIONS

=over 4

=item $netlist->find_module($name)

Returns Verilog::Netlist::Module matching given name.

=item $netlist->modules

Returns list of Verilog::Netlist::Module.

=item $netlist->modules_sorted

Returns name sorted list of Verilog::Netlist::Module.

=item $netlist->modules_sorted_level

Returns level sorted list of Verilog::Netlist::Module.  Leaf modules will
be first, the top most module will be last.

=item $netlist->new_module

Creates a new Verilog::Netlist::Module.

=item $netlist->new_root_module

Creates a new Verilog::Netlist::Module for $root, if one doesn't already
exist.

=item $netlist->top_modules_sorted

Returns name sorted list of Verilog::Netlist::Module, only for those
modules which have no children and are not unused library cells.

=back

=head1 FILE FUNCTIONS

=over 4

=item $netlist->dependency_write(I<filename>)

Writes a dependency file for make, listing all input and output files.

=item $netlist->defvalue_nowarn (I<define>)

Return the value of the specified define or undef.

=item $netlist->dependency_in(I<filename>)

Adds an additional input dependency for dependency_write.

=item $netlist->dependency_out(I<filename>)

Adds an additional output dependency for dependency_write.

=item $netlist->delete

Delete the netlist, reclaim memory.  Unfortunately netlists will not
disappear simply with normal garbage collection from leaving of scope due
to complications with reference counting and weaking Class::Struct
structures; solutions welcome.

=item $netlist->files

Returns list of Verilog::Netlist::File.

=item $netlist->files_sorted

Returns a name sorted list of Verilog::Netlist::File.

=item $netlist->find_file($name)

Returns Verilog::Netlist::File matching given name.

=item $netlist->read_file( filename=>$name)

Reads the given Verilog file, and returns a Verilog::Netlist::File
reference.

Generally called as $netlist->read_file.  Pass a hash of parameters.  Reads
the filename=> parameter, parsing all instantiations, ports, and signals,
and creating Verilog::Netlist::Module structures.

=item $netlist->read_libraries ()

Read any libraries specified in the options=> argument passed with the
netlist constructor.  Automatically invoked when netlist linking results in
a module that wasn't found, and thus might be inside the libraries.

=item $netlist->remove_defines (I<string>)

Expand any `defines in the string and return the results.  Undefined
defines will remain in the returned string.

=item $netlist->resolve_filename (I<string>, [I<lookup_type>])

Convert a module name to a filename.  Optional lookup_type is 'module',
'include', or 'all', to use only module_dirs, incdirs, or both for the
lookup.  Return undef if not found.

=item $self->verilog_text

Returns verilog code which represents the netlist.  The netlist must be
already ->link'ed for this to work correctly.

=back

=head1 BUGS

Cell instantiations without any arguments are not supported, a empty set of
parenthesis are required.  (Use "cell cell();", not "cell cell;".)

Order based pin interconnect is not supported, use name based connections.

=head1 DISTRIBUTION

Verilog-Perl is part of the L<http://www.veripool.org/> free Verilog EDA
software tool suite.  The latest version is available from CPAN and from
L<http://www.veripool.org/verilog-perl>.

Copyright 2000-2017 by Wilson Snyder.  This package is free software; you
can redistribute it and/or modify it under the terms of either the GNU
Lesser General Public License Version 3 or the Perl Artistic License Version 2.0.

=head1 AUTHORS

Wilson Snyder <wsnyder@wsnyder.org>

=head1 SEE ALSO

L<Verilog-Perl>,
L<Verilog::Netlist::Cell>,
L<Verilog::Netlist::File>,
L<Verilog::Netlist::Interface>,
L<Verilog::Netlist::Logger>,
L<Verilog::Netlist::ModPort>,
L<Verilog::Netlist::Module>,
L<Verilog::Netlist::Net>,
L<Verilog::Netlist::Pin>,
L<Verilog::Netlist::Port>,
L<Verilog::Netlist::Subclass>

And the L<http://www.veripool.org/verilog-mode>Verilog-Mode package for Emacs.

=cut
