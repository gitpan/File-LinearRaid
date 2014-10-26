package File::LinearRaid;

use strict;
use warnings;
use Symbol;
use Carp;
use vars '$VERSION';

$VERSION = '0.10';

sub new {
    my $pkg = shift;
    
    my $sym = gensym;
    tie *$sym, $pkg, @_;

    return bless $sym, $pkg;
}

sub TIEHANDLE {
    my $pkg = shift;
    my $mode = shift;
    
    my @files;
    my @sizes;
    my @handles;
    my $length = 0;
    
    while (my ($file, $size) = splice @_, 0, 2) {
        open my $fh, $mode, $file or croak "Couldn't open $file: $!\n";
        
        push @handles, $fh;
        push @files, $file;
        push @sizes, $size;
        $length += $size;
    }
    
    bless {
        pos     => 0,
        files   => \@files,
        sizes   => \@sizes,
        handles => \@handles,
        length  => $length,
        last_file => $#files
    }, $pkg;
}

sub READ {
    my ($self, undef, $length, $offset) = @_;
    
    $offset ||= 0;
    
    if ($self->EOF) {
        substr($_[1], $offset) = "";
        return 0;
    }
    
    my $pos = $self->{pos};

    my $f = 0;
    while ($pos >= $self->{sizes}[$f]) {
        $pos -= $self->{sizes}[$f];
        $f++;
    }
    
    my $b;
    
    my $this_read = ($pos + $length > $self->{sizes}[$f])
        ? $self->{sizes}[$f] - $pos
        : $length;
    
    seek $self->{handles}[$f], $pos, 0
        or croak "Couldn't seek $self->{files}[$f]";
    
    $b = read $self->{handles}[$f], $_[1], $this_read, $offset;

    defined $b or croak "Error reading from $self->{files}[$f]: $!";

    $self->{pos} += $this_read;
    
    if ( $b < $this_read ) {
        # pad out rest of chunk with nulls
        substr($_[1], $offset + $b) = "\x0" x ($this_read - $b);
    }

    if ($this_read == $length) {
        return $length;
    } else {
        return $this_read + $self->READ($_[1], $length - $this_read, $offset + $this_read);
    }
}

sub READLINE {
    my $self   = shift;
    my $oldpos = $self->{pos};

    return undef if $self->EOF;
    
    my $buf = "";
    
    if (not defined $/) {
        $self->READ($buf, $self->{length} - $oldpos);
    } elsif (ref $/) {
        $self->READ($buf, ${$/});
    } else {
        
        while (index($buf, $/) == -1 and not $self->EOF) {
            $self->READ($buf, 1024, length $buf);
        }
        
        if (index($buf, $/) != -1) {
            substr($buf, index($buf, $/) + length($/)) = "";
            $self->{pos} = $oldpos + length $buf;
        }
    }
    
    return $buf;
    
}

sub GETC {
    my $c;
    $_[0]->READ($c, 1);
    return $c;
}



sub WRITE {
    my ($self, undef, $length, $offset) = @_;
    
    $offset ||= 0;
    
    if ($self->EOF) {
        return 0;
    }
    
    my $pos = $self->{pos};

    my $f = 0;
    while ($pos >= $self->{sizes}[$f]) {
        $pos -= $self->{sizes}[$f];
        $f++;
    }
    
    my $this_write = ($pos + $length > $self->{sizes}[$f])
        ? $self->{sizes}[$f] - $pos
        : $length;
    
    seek $self->{handles}[$f], $pos, 0
        or croak "Couldn't seek $self->{files}[$f]";
    
    print { $self->{handles}[$f] } substr($_[1], $offset, $this_write)
        or return 0;

    $self->{pos} += $this_write;

    if ($this_write == $length) {
        return 1;
    } else {
        return $self->WRITE($_[1], $length - $this_write, $offset + $this_write);
    }
}

sub PRINT {
    my $self = shift;
    my $buf = join +(defined $, ? $, : "") => @_;
    $self->WRITE($buf, length($buf), 0);
}

sub PRINTF {
    my $self = shift;
    my $fmt  = shift;
    $self->PRINT( sprintf $fmt, @_ );
}



sub SEEK {
    my ($self, $offset, $whence) = @_;
    
    my $pos = $self->{pos};
    
    $whence == 0 and $pos = $offset;
    $whence == 1 and $pos += $offset;
    $whence == 2 and $pos = $self->{size} + $offset;

    return 0 if $pos < 0;
    $self->{pos} = $pos;
    return 1;
}

sub TELL {
    $_[0]->{pos};
}

sub EOF {
    my $self = shift;
    return $self->{pos} == $self->{length};
}

sub CLOSE {
    close $_ for @{ $_[0]->{handles} };
    $_[0] = undef;
}

sub OPEN {
    croak "OPEN Unimplemented";
}
1;

__END__

=head1 NAME

File::LinearRaid - Treat multiple files as one large seamless file for reading
and writing.

=head1 SYNOPSIS

  use File::LinearRaid;
  
  my $fh = File::LinearRaid->new( "+<",
      "data/datafile0" => 100_000,
      "data/datafile1" =>  50_000,
      "data/datafile2" => 125_000
  );

  ## this chunk of data actually crosses a physical file boundary
  seek $fh, 90_000, 0;
  read $fh, my $buffer, 20_000;
  
  ## replace that chunk with X's
  seek $fh, 90_000, 0;
  print $fh "X" x 20_000;

=head1 DESCRIPTION

This module provides a single-filehandle interface to multiple files, in much
the same way that a linear RAID provides a single-device interface to multiple
physical hard drives.

This module was written to provide random fixed-width record access to a
series of files. For example, in the BitTorrent filesharing protocol, several
files are shared as a single entity. The final sizes of the individual files
are known, but the protocol only sends fixed-width chunks of data. These
chunks are not aligned to file boundaries and can span several physical files,
but they are only identified by their number and not by the files they span.

This module was created to provide a layer of abstraction around this kind of
storage. Instead of calculating possibly many file offsets, and dividing
data into smaller pieces, a simple seek and read (or print) on the abstract
filehandle will do the right thing, regardless of how the chunk spans the
physical files:

  seek $fh, ($chunk_id * $chunk_size), 0;
  read $fh, my $buffer, $chunk_size;
  
  ## or if opened with mode "+<" or similar:
  
  seek $fh, ($chunk_id * $chunk_size), 0;
  print $fh $chunk;

At this time the module is still beta quality, but most common file activities
should work fine.

=head1 USAGE

  File::LinearRaid->new( $mode, $path1 => $size1, ... )

Returns a new File::LinearRaid object consisting of the listed paths. Each
physical file is opened using the given mode.

Each file needs an associated maximum length. This need not be the current
length of the file. If the file is shorter than this length, the LinearRaid
filehandle will behave as if the file were null-padded to this length
(although it will not modify the file for reading). If the file is longer than
this length, the portion of thie file past this length will be ignored (but
preserved). When writing to the LinearRaid filehandle for random access, the
physical files will be grown (with null characters) as needed.

Currently, read, readline, print, getc and friends are implemented, so you
should be able to use most file operations seamlessly. Writing beyond the
specified limit of the final physical file is not supported.

=head1 CAVEATS

This module is currently not much more than proof-of-concept. Although there
is a test suite, things might not be perfect yet.

=over

=item *

Probably doesn't play well with unicode / wide characters.

=item *

Error checking is quite limited.

=item *

Formats are untested, I don't use them and don't know if they'll work.

=back

=head1 AUTHOR

File::LinearRaid is written by Mike Rosulek E<lt>mike@mikero.comE<gt>. Feel 
free to contact me with comments, questions, patches, or whatever.

=head1 COPYRIGHT

Copyright (c) 2004 Mike Rosulek. All rights reserved. This module is free 
software; you can redistribute it and/or modify it under the same terms as Perl 
itself.
