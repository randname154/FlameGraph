#!/usr/bin/perl -w
#
# stackcollapse-instruments-cpucycle.pl
#
# Parses a file containing a call tree as produced by XCode Instruments cpu profiler
# (Edit > Deep Copy) and produces output suitable for flamegraph.pl.
#
# USAGE: ./stackcollapse-instruments.pl infile > outfile

use strict;

my @stack = ();

<>;
foreach (<>) {
    chomp;
    /\d+(?:\.\d+)? (?:Gc|Mc|Kc|cycles)\s+\d+\.\d+%\s+(-|(\d+(?:\.\d+)?) (Gc|Mc|Kc|cycles))\t \t(\s*)(.+)/ or die;
    my $func = $5;
    my $depth = length ($4);
    $stack[$depth] = $5;
    foreach my $i (0 .. $depth - 1) {
	print $stack[$i];
	print ";";
    }
    
    my %unit_map = (
	'Gc' => 1_000_000_000,  # 10^9 cycles
        'Mc' => 1_000_000,       # 10^6
        'Kc' => 1_000,           # 10^3
        'cycles' => 1
	);
    
    my $time = 0;
    if ($1 ne "-") {
	$time = $2 * $unit_map{$3};
    }
    
    printf("%s %.0f\n", $func, $time);
}
