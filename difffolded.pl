#!/usr/bin/perl -w
#
# difffolded.pl         diff two folded stack files. Use this for generating
#                       flame graph differentials.
#
# USAGE: ./difffolded.pl [-hnspkzZ] folded1 folded2 | ./flamegraph.pl > diff2.svg
#
# The script has four primary modes of operation:
#   default:    Show stacks present in either file, with their respective counts
#   -k:         Keep and show all stacks, even those with zero counts
#   -p:         Propagate differences up the stack by accumulating child counts
#   -k -p:      Combine both -k and -p: show all stacks with propagated counts
#
# Additional options:
#   -n:         Normalize sample counts between files
#   -s:         Strip hex numbers (addresses) from stacks
#   -z:         Elide frames where the difference is below threshold
#   -Z NUM:     Set threshold for -z (default: 0.01, meaning 1%)
#   -d:         Enable debug mode
#
# The flamegraph will be colored based on higher samples (red) and smaller
# samples (blue). The frame widths will be based on the 2nd folded file.
# This might be confusing if stack frames disappear entirely; it will make
# the most sense to ALSO create a differential based on the 1st file widths,
# while switching the hues; eg:
#
#  ./difffolded.pl folded2 folded1 | ./flamegraph.pl --negate > diff1.svg
#
# Here's what they mean when comparing a before and after profile:
#
# diff1.svg: widths show the before profile, colored by what WILL happen
# diff2.svg: widths show the after profile, colored by what DID happen
#
# INPUT: See stackcollapse* programs.
#
# OUTPUT: The full list of stacks, with two columns, one from each file.
# If a stack wasn't present in a file, the column value is zero.
#
# folded_stack_trace count_from_folded1 count_from_folded2
#
# eg:
#
# funca;funcb;funcc 31 33
# ...
#
# COPYRIGHT: Copyright (c) 2014 Brendan Gregg.
#
#  This program is free software; you can redistribute it and/or
#  modify it under the terms of the GNU General Public License
#  as published by the Free Software Foundation; either version 2
#  of the License, or (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with this program; if not, write to the Free Software Foundation,
#  Inc., 59 Temple Place - Suite 330, Boston, MA  02111-1307, USA.
#
#  (http://www.gnu.org/copyleft/gpl.html)
#
# 28-Oct-2014	Brendan Gregg	Created this.

use strict;
use Getopt::Std;

# Disable deep recursion warnings
no warnings 'recursion';

# defaults
my $normalize = 0;           # make sample counts equal
my $striphex = 0;            # strip hex numbers
my $propdiff = 0;            # propagate difference
my $keep_all = 0;            # keep all stacks even when counts are zero
my $debug = 0;               # enable debugging
my $elide_insignificant = 0; # elide unchanged frames
my $threshold = 0.01;        # threshold for considering a change significant

sub usage {
    print STDERR <<USAGE_END;
USAGE: $0 [-hnspuzZ] folded1 folded2 | flamegraph.pl > diff2.svg
    -d       # debug mode
    -h       # help message
    -Z NUM   # set threshold for significant change (default 0.01)
    -k       # keep all stacks (including those with zero counts)
    -n       # normalize sample counts
    -p       # propagate difference
    -s       # strip hex numbers (addresses)
    -z       # elide insignificant frames
USAGE_END
    exit 2;
}

usage() if @ARGV < 2;
our ($opt_h, $opt_n, $opt_s, $opt_p, $opt_k, $opt_z, $opt_Z, $opt_d);
getopts('hnspkzZ:d') or usage();
usage() if $opt_h;
$normalize = 1 if defined $opt_n;
$striphex = 1 if defined $opt_s;
$propdiff = 1 if defined $opt_p;
$keep_all = 1 if defined $opt_k;
$elide_insignificant = 1 if defined $opt_z;
$threshold = $opt_Z if defined $opt_Z;
$debug = 1 if defined $opt_d;

my ($total1, $total2) = (0, 0);
my %Folded;
my %Tree;

my $file1 = $ARGV[0];
my $file2 = $ARGV[1];

sub add_to_tree {
    my ($stack, $count, $file_num) = @_;
    my @frames = split /;/, $stack;
    my $node = \%Tree;
    for my $frame (@frames) {
        $node->{children}{$frame} //= {};
        $node = $node->{children}{$frame};
    }
    $node->{count}{$file_num} += $count;
}

sub read_file {
    my ($filename, $file_num) = @_;
    open my $fh, '<', $filename or die "ERROR: Can't read $filename: $!\n";
    while (<$fh>) {
        chomp;
        my ($stack, $count) = (/^(.*)\s+?(\d+(?:\.\d*)?)$/);
        next unless defined $stack and defined $count;
        $stack =~ s/0x[0-9a-fA-F]+/0x.../g if $striphex;
        $Folded{$stack}{$file_num} += $count;
        add_to_tree($stack, $count, $file_num) if ($propdiff || $keep_all);
        $file_num == 1 ? $total1 += $count : $total2 += $count;
    }
    close $fh;
}

sub process_default {
    my @output;
    foreach my $stack (keys %Folded) {
        my $count1 = $Folded{$stack}{1} // 0;
        my $count2 = $Folded{$stack}{2} // 0;
        if ($normalize && $total1 != $total2) {
            $count1 = int($count1 * $total2 / $total1);
        }
        my $diff = $count2 - $count1;
        my $diff_percent = $count1 ? (abs($diff) / $count1) * 100 : ($count2 ? 100 : 0);
        if (!$elide_insignificant || $diff_percent >= $threshold) {
            push @output, [$stack, $count1, $count2, $diff];
        }
    }
    return \@output;
}

sub process_tree {
    my ($node, $stack, $propdiff_mode) = @_;
    my @output;

    return (\@output, 0, 0) unless $node && ref($node) eq 'HASH';

    my $count1 = $node->{count}{1} // 0;
    my $count2 = $node->{count}{2} // 0;

    if ($normalize && $total1 != $total2) {
        $count1 = int($count1 * $total2 / $total1);
    }

    my $total_count1 = $count1;
    my $total_count2 = $count2;

    # Process children
    for my $child (sort keys %{$node->{children}}) {
        my ($child_output, $child_count1, $child_count2) =
            process_tree($node->{children}{$child},
                        $stack ? "$stack;$child" : $child,
                        $propdiff_mode);

        push @output, @$child_output;

        if ($propdiff_mode) {
            $total_count1 += $child_count1;
            $total_count2 += $child_count2;
        }
    }

    # Determine whether to output this node
    if ($stack) {
        my $final_count1 = $propdiff_mode ? $total_count1 : $count1;
        my $final_count2 = $propdiff_mode ? $total_count2 : $count2;
        my $diff = $final_count2 - $final_count1;
        my $diff_percent = $final_count1 ? (abs($diff) / $final_count1) * 100 : ($final_count2 ? 100 : 0);

        if (!$elide_insignificant || $diff_percent >= $threshold) {
            push @output, [$stack, $final_count1, $final_count2, $diff];
        }
    }

    return (\@output, $total_count1, $total_count2);
}

read_file($file1, 1);
read_file($file2, 2);

my $output;
if ($keep_all || $propdiff) {
    print STDERR "DEBUG: Using " .
                ($keep_all ? "keep-all" : "") .
                ($keep_all && $propdiff ? " with " : "") .
                ($propdiff ? "propagation" : "") .
                " mode\n" if $debug;

    my ($tree_output) = process_tree(\%Tree, "", $propdiff);
    $output = $tree_output;
} else {
    print STDERR "DEBUG: Using default mode\n" if $debug;
    $output = process_default();
}

print STDERR "DEBUG: Total counts - Old: $total1, New: $total2\n" if $debug;

# Sort and print output
foreach my $line (sort { $a->[0] cmp $b->[0] } @$output) {
    my ($stack, $count1, $count2, $diff) = @$line;
    printf STDERR "DEBUG: %s %d %d (diff: %+d)\n", $stack, $count1, $count2, $diff if $debug;
    printf "%s %d %d\n", $stack, $count1, $count2;
}

print STDERR "DEBUG: Script execution completed\n" if $debug;
