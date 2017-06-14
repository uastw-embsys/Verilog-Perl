# Verilog - Verilog Perl Interface
# See copyright, etc in below POD section.
######################################################################

package Verilog::Netlist::Pin;

use Verilog::Netlist;
use Verilog::Netlist::Port;
use Verilog::Netlist::Net;
use Verilog::Netlist::Cell;
use Verilog::Netlist::Module;
use Verilog::Netlist::Pin;
use Verilog::Netlist::Subclass;
use vars qw($VERSION @ISA);
use strict;
@ISA = qw(Verilog::Netlist::Pin::Struct
	Verilog::Netlist::Subclass);

$VERSION = '3.427';

structs('_new_base',
	'Verilog::Netlist::Pin::Struct'
	=>[name     	=> '$', #'	# Pin connection
	   filename 	=> '$', #'	# Filename this came from
	   lineno	=> '$', #'	# Linenumber this came from
	   userdata	=> '%',		# User information
	   attributes	=> '%', #'	# Misc attributes for systemperl or other processors
	   #
	   comment	=> '$', #'	# Comment provided by user
	   _netnames	=> '$', #'	# Arrayref to net descriptors
	   portname 	=> '$', #'	# Port connection name
	   portnumber   => '$', #'	# Position of name in call
	   pinnamed 	=> '$', #'	# True if name assigned
	   cell     	=> '$', #'	# Cell reference
	   # below only after link()
	   _nets	=> '$', #'	# Arrayref to references to connected nets
	   port		=> '$', #'	# Port connection reference
	   # SystemPerl: below only after autos()
	   sp_autocreated => '$', #'	# Created by auto()
	   # below by accessor computation
	   #module
	   #submod
	   ]);

sub new {
    my $class = shift;
    my %params = (@_);
    if (defined $params{netname}) {
	# handle legacy instructor parameter "netname"
	$params{_netnames} = [{netname=>$params{netname}}];
	delete $params{netname};
    } elsif (defined $params{netnames}) {
	# remap netnames to _netnames
	$params{_netnames} = $params{netnames};
	delete $params{netnames};
    }
    return $class->_new_base (%params);
}

sub delete {
    my $self = shift;
    if ($self->nets && $self->port) {
	foreach my $net ($self->nets) {
	    next unless $net->{net};
	    my $dir = $self->port->direction;
	    if ($dir eq 'in') {
		$net->{net}->_used_in_dec();
	    } elsif ($dir eq 'out') {
		$net->{net}->_used_out_dec();
	    } elsif ($dir eq 'inout') {
		$net->{net}->_used_inout_dec();
	    }
	}
    }
    my $h = $self->cell->_pins;
    delete $h->{$self->name};
    return undef;
}

######################################################################
#### Methods
# Legacy accessors
sub netname {
    return undef if !defined($_[0]->_netnames);
    return @{$_[0]->_netnames}[0]->{netname};
}
sub net {
    return undef if !defined($_[0]->_nets);
    return @{$_[0]->_nets}[0];
}

sub nets {
    return [] if !defined($_[0]->_nets);
    return (@{$_[0]->_nets});
}
sub nets_sorted {
    return [] if !defined($_[0]->_nets);
    return (sort {$a->name() cmp $b->name()} (@{$_[0]->_nets}));
}
sub netnames {
    return [] if !defined($_[0]->_netnames);
    return @{$_[0]->_netnames};
}
sub logger {
    return $_[0]->netlist->logger;
}
sub module {
    return $_[0]->cell->module;
}
sub submod {
    return $_[0]->cell->submod;
}
sub netlist {
    return $_[0]->cell->module->netlist;
}

sub _bracketed_msb_lsb {
    my $self = shift;
    my $netname = shift;
    my $out = "";
    # Handle sized constant numbers (e.g., 7'b0) distinctively
    if ($netname->{netname} =~ /^'/) {
	$out .= $netname->{msb} + 1;
	$out .= $netname->{netname};
    } else {
	$out .= $netname->{netname};
	if (defined $netname->{msb}) {
	    if ($netname->{msb} == $netname->{lsb}) {
		$out .= "[".$netname->{msb}."]";
	    } else {
		$out .= "[".$netname->{msb}.":".$netname->{lsb}."]";
	    }
	}
    }
    return $out;
}

sub _link {
    my $self = shift;
    # Note this routine is HOT
    my $change;
    if (!$self->_nets) {
	if ($self->_netnames) {
	    my @nets = ();
	    foreach my $netname ($self->netnames) {
		my $net = $self->module->find_net($netname->{netname});
		next if (!defined($net));
		my ($msb, $lsb);
		# if the parsed description includes a range, use that,
		# else use the complete range of the underlying net.
		if (defined($netname->{msb})) {
		    $msb = $netname->{msb};
		    $lsb = $netname->{lsb};
		} else {
		    $msb = $net->msb;
		    $lsb = $net->lsb;
		}
		push(@nets, {net => $net, msb => $msb, lsb => $lsb});
	    }
	    $self->_nets(\@nets);
	    $change = 1;
	}
    }
    if (!$self->port) {
	if (my $submod = $self->submod) {
	    my $portname = $self->portname;
	    if ($portname && !$self->cell->byorder ) {
		$self->port($submod->find_port($portname));
		$change = 1;
	    }
	    else {
		$self->port($submod->find_port_by_index($self->portnumber));
		# changing name from pin# to actual port name
		$self->name($self->port->name) if $self->port;
		$change = 1;
	    }
	}
    }
    if ($change && $self->_nets && $self->port) {
	my $dir = $self->port->direction;
	foreach my $net ($self->nets) {
	    next unless $net->{net};
	    if ($dir eq 'in') {
		$net->{net}->_used_in_inc();
	    } elsif ($dir eq 'out') {
		$net->{net}->_used_out_inc();
	    } elsif ($dir eq 'inout') {
		$net->{net}->_used_inout_inc();
	    }
	}
    }
}

sub type_match {
    my $self = shift;
    # We could check for specific types being OK, but nearly everything,
    # reg/trireg/wire/wand etc/tri/ supply0|1 etc
    # is allowed to connect with everything else, and we're not a lint tool...
    # So, not: return $self->net->data_type eq $self->port->data_type;
    return 1;
}

sub lint {
    my $self = shift;
    if (!$self->port && $self->submod) {
        $self->error ($self,"Port not found in ",$self->submod->keyword," ",$self->submod->name,": ",$self->portname,"\n");
    }
    if ($self->port && $self->_nets) {
	if (!$self->type_match) {
		# FIXME
	    my $nettype = $self->net->data_type;
	    my $porttype = $self->port->data_type;
	    $self->error("Port pin data type '$porttype' != Net data type '$nettype': "
			 ,$self->name,"\n");
	}
	
	foreach my $net ($self->nets) {
	    next unless $net->{net} && $net->{net}->port;
	    my $portdir = $self->port->direction;
	    my $netdir = $net->{net}->port->direction;
	    if (($netdir eq "in" && $portdir eq "out")
		#Legal: ($netdir eq "in" && $portdir eq "inout")
		#Legal: ($netdir eq "out" && $portdir eq "inout")
		) {
		$self->error("Port is ${portdir}put from submodule, but ${netdir}put from this module: "
			     ,$self->name,"\n");
		#$self->cell->module->netlist->dump;
	    }
	}
    }
}

sub verilog_text {
    my $self = shift;
    my $inst;
    if ($self->port) {  # Even if it was by position, after linking we can write it as if it's by name.
	$inst = ".".$self->port->name."(";
    } elsif ($self->pinnamed) {
	$inst = ".".$self->name."(";
    } else { # not by name, and unlinked
	return $self->{_netnames};
    }
    my $net_cnt = $self->netnames;
    if ($net_cnt > 1) {
	$inst .= "{";
    }
    foreach my $netname (reverse($self->netnames)) {
	$inst .= $self->_bracketed_msb_lsb($netname);
	$inst .= ",";
    }
    chop($inst); # remove superfluous ,
    if ($net_cnt > 1) {
	$inst .= "}";
    }
    $inst .= ")";
    return $inst;
}

sub dump {
    my $self = shift;
    my $indent = shift||0;
    my $out = " "x$indent."Pin:".$self->name."  Nets:";
    foreach my $netname (reverse($self->netnames)) {
	$out .= $self->_bracketed_msb_lsb($netname);
	$out .= ",";
    }
    if (scalar($self->netnames) ne 0) {
	chop($out);
    }
    print "$out\n";
    if ($self->port) {
	$self->port->dump($indent+10, 'norecurse');
    }
    if ($self->_nets) {
	foreach my $net ($self->nets) {
	    next unless $net->{net};
	    $net->{net}->dump($indent+10, 'norecurse');
	}
    }
}

######################################################################
#### Package return
1;
__END__

=pod

=head1 NAME

Verilog::Netlist::Pin - Pin on a Verilog Cell

=head1 SYNOPSIS

  use Verilog::Netlist;

  ...
  my $pin = $cell->find_pin ('pinname');
  print $pin->name;

=head1 DESCRIPTION

A Verilog::Netlist::Pin object is created by Verilog::Netlist::Cell for for
each pin connection on a cell.  A Pin connects a net in the current design
to a port on the instantiated cell's module.

=head1 ACCESSORS

See also Verilog::Netlist::Subclass for additional accessors and methods.

=over 4

=item $self->cell

Reference to the Verilog::Netlist::Cell the pin is under.

=item $self->comment

Returns any comments following the definition.  keep_comments=>1 must be
passed to Verilog::Netlist::new for comments to be retained.

=item $self->delete

Delete the pin from the cell it's under.

=item $self->module

Reference to the Verilog::Netlist::Module the pin is in.

=item $self->name

The name of the pin.  May have extra characters to make vectors connect,
generally portname is a more readable version.  There may be multiple pins
with the same portname, only one pin has a given name.

=item $self->net

Reference to the Verilog::Netlist::Net the pin connects to.  Only valid after a link.

=item $self->netlist

Reference to the Verilog::Netlist the pin is in.

=item $self->netname

The net name the pin connects to.

=item $self->portname

The name of the port connected to.

=item $self->port

Reference to the Verilog::Netlist::Port the pin connects to.  Only valid after a link.

=back

=head1 MEMBER FUNCTIONS

See also Verilog::Netlist::Subclass for additional accessors and methods.

=over 4

=item $self->lint

Checks the pin for errors.  Normally called by Verilog::Netlist::lint.

=item $self->dump

Prints debugging information for this pin.

=back

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
L<Verilog::Netlist::Subclass>
L<Verilog::Netlist>

=cut
