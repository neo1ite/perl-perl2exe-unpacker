package Perl2Exe::Unpacker;

use 5.014002;
use strict;
use warnings;

use Fcntl qw/:seek/;
use File::Basename;
use File::Path qw/make_path/;
use File::Spec::Functions;

require Exporter;
use AutoLoader qw(AUTOLOAD);

our @ISA = qw(Exporter);

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.

# This allows declaration	use Perl2Exe::Unpacker ':all';
# If you do not need this, moving things directly into @EXPORT or @EXPORT_OK
# will save memory.
our %EXPORT_TAGS = ( 'all' => [ qw(

) ] );

our @EXPORT_OK = ( @{ $EXPORT_TAGS{'all'} } );

our @EXPORT = qw(

);

our $VERSION = '0.01';


# Preloaded methods go here.

# Autoload methods go after =cut, and are processed by the autosplit program.

sub new {
    my ($invocant, $file_name) = @_;
    return if (!-e $file_name || -z $file_name);
    warn "warning: $file_name isn't binary file!\n" unless (-B $file_name);

    my $class = ref($invocant) || $invocant;
    my $self = { };

    open($self->{_FH}, '<', $file_name) or die "Can't open file $file_name: $!";
    binmode($self->{_FH});
    bless($self, $class);

    $self->{toc_hdr_size} = 0x100;
    $self->{size}         = (-s $self->{_FH});
    $self->{src_dir}      = $file_name . '.src';
    $self->{key}          = $self->rc4('For more information visit www.indigostar.com', 'continue');

    return $self;
}

sub DESTROY {
    my ($self) = @_;
    close($self->{_FH});
}

sub _get_toc {
    my ($self, $dump_toc, $verbose) = @_;

    my $encrypted_toc_str;
    seek($self->{_FH}, -$self->{toc_hdr_size}, SEEK_END);
    read($self->{_FH}, $encrypted_toc_str, $self->{toc_hdr_size});
    $self->{toc_hdr} = $self->rc4($encrypted_toc_str);
    ($self->{toc_name}, $self->{toc_size}) = $self->{toc_hdr} =~ /NAME=(.+?);SIZE=(\d+)/;
    warn "warning: unknown archive type\n" unless ($self->{toc_name} eq 'P2X-V06.TOC');

    my $encrypted_toc;
    seek($self->{_FH}, -($self->{toc_hdr_size} + $self->{toc_size}) , SEEK_END);
    read($self->{_FH}, $encrypted_toc, $self->{toc_size});
    $self->{toc} = $self->rc4($encrypted_toc);

    if ($dump_toc) {
        print "$self->{toc_name} ($self->{toc_size}) [encoded] " if $verbose;
        open(my $_TOC_FH, '>', $self->{toc_name}) or die "Can't open file $self->{toc_name}: $!";
        binmode($_TOC_FH);
        print $_TOC_FH $self->{toc};
        close($_TOC_FH);
        print "ok\n" if $verbose;
    }

    return $self->{toc};
}

sub get_toc {
    my ($self, $params) = @_;
    $params //= {};

    return $self->{toc} || $self->_get_toc($params->{dump_toc} ? 1 : 0);
}

sub _get_toc_files {
    my ($self) = @_;

    foreach my $line (split("\n", $self->{toc})) {
        my (%file, $key, $value);

        ($file{name}, $file{size}, $key, $value) = $line =~ /NAME=(.+?);SIZE=(\d+)(?:;(\p{XPosixUpper}+)=(.*))?/;#(.*?)$/;
        $file{lc($key)} = $value if $key;
        $self->{toc_files_size} += $file{size};

        push @{$self->{toc_files}}, \%file;
    }
    $self->{toc_files_offset} = $self->{size} - ($self->{toc_files_size} + $self->{toc_size} + $self->{toc_hdr_size});

    return $self->{toc_files};
}

sub get_toc_files {
    my ($self) = @_;

    return $self->{toc_files} || $self->_get_toc_files();
}

sub _dump_files {
    my ($self, $verbose) = @_;

    my $fcount = 0;
    seek($self->{_FH}, $self->{toc_files_offset}, SEEK_SET);
    foreach my $file (@{$self->{toc_files}}) {
        if ($file->{size} > 0) {
            my $path = dirname($file->{name}) =~ s/^\.$//r;
            make_path(catfile($self->{src_dir}, $path), { error => \my $err });
            die "Can't create path $path: $err->[0]{$path}" if @{$err};

            my $file_name = catfile($self->{src_dir}, $file->{name});

            read($self->{_FH}, my $file_content, $file->{size});
            $file_content = $self->rc4($file_content) if $file->{enc};

            print "$file_name ($file->{size}) " . ($file->{enc} ? '[encoded] ' : '') if $verbose;
            open(my $_FH, '>', $file_name) or die "Can't open file $file_name: $!";
            binmode($_FH);
            print $_FH $file_content;
            close($_FH);
            print "ok\n" if $verbose;

            $fcount++;
        }
    }

    return $fcount;
}

sub dump_files {
    my ($self, $params) = @_;
    $params //= {};

    $self->_get_toc($params->{dump_toc} ? 1 : 0, $params->{verbose} ? 1 : 0) unless $self->{toc};
    $self->_get_toc_files() unless ($self->{toc_files} && @{$self->{toc_files}});

    return $self->_dump_files($params->{verbose} ? 1 : 0);
}

sub rc4 {
    my ($self, $str, $key) = @_;
    $key ||= $self->{key};

    my ($x, $y) = (0, 0);
    my @s = (0x00 .. 0xFF);
    my @k = unpack('C*', $key);

    for ($x = 0; $x < 0x100; $x++) {
        $y = ($k[$x % @k] + $s[$x] + $y) % 0x100;

        @s[$x, $y] = @s[$y, $x];
    }

    $x = $y = 0;
    my $z = undef;

    for (unpack('C*', $str)) {
        $x = ($x + 1) % 0x100;
        $y = ($s[$x] + $y) % 0x100;

        @s[$x, $y] = @s[$y, $x];

        $z .= pack('C', $_ ^= $s[($s[$x] + $s[$y]) % 0x100])
    }

    return $z
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

Perl2Exe::Unpacker - Perl extension for blah blah blah

=head1 SYNOPSIS

  use Perl2Exe::Unpacker;
  blah blah blah

=head1 DESCRIPTION

Stub documentation for Perl2Exe::Unpacker, created by h2xs. It looks like the
author of the extension was negligent enough to leave the stub
unedited.

Blah blah blah.

=head2 EXPORT

None by default.



=head1 SEE ALSO

Mention other useful documentation such as the documentation of
related modules or operating system documentation (such as man pages
in UNIX), or any relevant external documentation such as RFCs or
standards.

If you have a mailing list set up for your module, mention it here.

If you have a web site set up for your module, mention it here.

=head1 AUTHOR

A. U. Thor, E<lt>a.u.thor@a.galaxy.far.far.awayE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2016 by A. U. Thor

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.16.3 or,
at your option, any later version of Perl 5 you may have available.


=cut
