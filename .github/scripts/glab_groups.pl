#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use lib "$Bin/../../lib";

use GlabGroups qw(run_cli);

exit run_cli(@ARGV);
