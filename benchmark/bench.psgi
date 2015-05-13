#!/usr/bin/env perl

use strict;
use warnings;
use Plack::App::File;
my $app = Plack::App::File->new(root => '..');

__END__
