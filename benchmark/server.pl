#!/usr/bin/env perl

use strict;
use warnings;

use Getopt::Long qw(GetOptions);

my $host = '127.0.0.1';
my $workers = 16;

GetOptions(
    'host=s'        => \$host,
    'workers=i'     => \$workers,
) or die "bad option";

exec("starman --host $host --workers $workers app.psgi");
