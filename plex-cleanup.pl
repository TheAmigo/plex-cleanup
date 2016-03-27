#!/usr/bin/perl -w

# The MIT License (MIT)
#
# Copyright (c) 2016 Josh Harding <theamigo@gmail.com>
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

# Future ideas:
#  - A configurable file name mapping for when this script runs on a host other
#      than the PMS and the absolute path to files isn't the same.
#  - Additional selection criteria (e.g. duration?)
#  - Default config options that would apply to all listed libraries that don't
#      otherwise specify.
#  - Test on platforms other than linux.

use strict;
use AnyEvent;
use AnyEvent::HTTP;
use XML::LibXML;
use Getopt::Long;
use Carp;
use POSIX qw/strftime/;

$|=1;

# Function prototypes
sub writeLog ($;$);

# Argument parsing
my $configFile = "$ENV{HOME}/.config/plex-cleanup.conf";
my $HELP;
my $VERBOSE = 0;
my $options = GetOptions(
	'help'      => \$HELP,
	'config=s'  => \$configFile,
	'verbose+'  => \$VERBOSE,
) || usage("ERROR: Invalid arguments");
usage("Showing help") if $HELP;

sub usage {
	my ($reason) = @_;
	print "$reason\n";
	print "Usage: $0 [-h]\n";
	print "       $0 [-v] [--config FILE]\n";
	print "\n";
	print "Deletes files in specified Plex libraries based on configurable criteria.\n";
	print "\n";
	print "    -h,--help           Show this help text.\n";
	print "    -c,--config FILE    Config file name (default: ~/.config/plex-cleanup.conf)\n";
	print "    -v,--verbose        Print extra logging information.\n";
	print "\n";
	print "Runs in test mode when STDIN is a tty and only shows what would be deleted.\n";
	print "To run in live mode, make sure STDIN isn't a tty. That will be automatic when\n";
	print "run from cron. When run from a terminal, use </dev/null to run in live mode.\n";
	print "\n";
	print "A single -v will list every file that's deleted.\n";
	print "A second -v will also list every file that's kept, and include stats about each.\n";
	exit 1;
}

# Global variables
my $AGEUNITS = {
	# Multipliers for units of time
	s       => 1,
	sec     => 1,
	secs    => 1,
	second  => 1,
	seconds => 1,

	m       => 60,
	min     => 60,
	mins    => 60,
	minute  => 60,
	minutes => 60,

	h     => 3600,
	hour  => 3600,
	hours => 3600,

	d    => 86400,
	day  => 86400,
	days => 86400,
};
# Valid suffixes for size:
my $SI = 'bKMGTPEZY';

# List of config items that are boolean values
my $BOOL_CONF = {continue_on_error => 1, watched_only => 1};
# List of 'true' values, everything else is false
my $BOOL_MAP = {t => 1, true => 1, y => 1, yes => 1, on => 1, 1 => 1};

# Initialization
my $TEST = -t STDIN;
if ($TEST) {
	print "Running in TEST MODE, no changes will be made.  To run in live mode, use </dev/null\n";
}

# Read in config file
my $config = readConfig($configFile);

# Base URL for Plex Media Server
my $BASE = "http://$config->{main}{plexhost}:$config->{main}{plexport}";

# Get a list of libraries on the server
my $libraries = getLibraries();

# Cleanup all libraries in config file
for my $libName (sort keys %{$config->{libraries}}) {
	cleanupLib($libName);
}

# End of main body

sub cleanupLib {
	my ($libName) = @_;

	if (!exists $libraries->{$libName}) {
		writeLog "WARNING: can't find library '$libName' on PMS, skipping.\n";
		return;
	}
	my $lib = $libraries->{$libName};
	my $conf = $config->{libraries}{$libName};

	# Check that it has exactly one mode specified
	my ($modes, $mode);
	$modes++ if defined $conf->{age};
	$modes++ if defined $conf->{size};
	$modes++ if defined $conf->{count};
	if ($modes != 1) {
		writeLog "ERROR: library '$libName' must have exactly one of: age, size, or count.  Skipping cleanup of this library.\n";
		return;
	} elsif (defined $conf->{age}) {
		$mode = 'Age';
	} elsif (defined $conf->{size}) {
		$mode = 'Size';
	} elsif (defined $conf->{count}) {
		$mode = 'Count';
	}

	writeLog "Cleaning up library $libName";

	# Get list of files in this library
	my $videos;
	for my $videoNode (getNodes("library/sections/$lib->{key}/all/", 'MediaContainer/Video')) {
		my @files;
		for my $mediaNode (childElements($videoNode)) {
			for my $partNode (childElements($mediaNode)) {
				my $partAttrs = attrs_to_hash($partNode);
				push @files, $partAttrs->{file};
			}
		}
		my $videoAttrs = attrs_to_hash($videoNode);
		$videos->{$videoAttrs->{ratingKey}} = {
			title => $videoAttrs->{title},
			files => \@files,
			views => $videoAttrs->{viewCount},
		};
	}
	writeLog "  Found " . (keys %$videos) . " videos, gathering metadata...";

	# For each video, get its rating.
	for my $videoKey (keys %$videos) {
		my $videoMeta = (getNodes("library/metadata/$videoKey", 'MediaContainer/Video'))[0];
		my $videoMetaAttrs = attrs_to_hash($videoMeta);
		$videos->{$videoKey}{userRating} = $videoMetaAttrs->{userRating};

		# For each file, get its age and size.
		for my $fileName (@{$videos->{$videoKey}{files}}) {
			my ($size, $mtime) = (stat $fileName)[7, 9];
			$videos->{$videoKey}{$fileName} = {
				size  => $size,
				age   => $^T - $mtime,
			};
		}
	}

	# Convert hash of videos into hash of files
	my $files;
	for my $videoKey (keys %$videos) {
		for my $fileName (@{$videos->{$videoKey}{files}}) {
			$files->{$fileName} = {
				size => $videos->{$videoKey}{$fileName}{size},
				age  => $videos->{$videoKey}{$fileName}{age},
				userRating => $videos->{$videoKey}{userRating},
				views => $videos->{$videoKey}{views} // 0,
			};
		}
	}

	# Cleanup based on the mode
	my $funcName = "deleteBy$mode";
	my $codeRef = \&$funcName;
	my $delCount = $codeRef->($files, $conf) // 0;

	writeLog "Done cleaning up '$libName', " . ($TEST ? 'would have ' : '' ) . "deleted $delCount file" . ($delCount == 1 ? '' : 's');
}

# Delete all files older than a certain age
sub deleteByAge {
	my ($files, $conf) = @_;
	my $maxAge = $conf->{age};
	my $delCount = 0;
	writeLog "  Deleting any files older than $maxAge seconds.";
	# Sure, we could sort by date and then stop the loop when we find one that's too new.
	# But this way prints verbose output in the same order regardless of mode.
	for my $fileName (sortByPref($files)) {
		my $age = $files->{$fileName}{age};
		my $action = 'keep';
		$action = 'delete' if $age > $maxAge && (!$conf->{watched_only} || $files->{$fileName}{views});
		my $deleted = actionFile($action, $files, $fileName);
		if ($action eq 'delete') {
			if ($deleted) {
				$delCount++;
			} elsif (!$conf->{continue_on_error}) {
				writeLog "  Not attempting to delete any more files in this library, set continue_on_error=True to override this.";
				last;
			}
		}
	}
	return $delCount;
}

# Delete enough files to get a library down under the given size
sub deleteBySize {
	my ($files, $conf) = @_;
	my $maxSize = $conf->{size};

	# Add sizes of all files in the library
	my ($fileSum, $delCount);
	for my $fileName (keys %$files) {
		$fileSum += $files->{$fileName}{size};
	}

	# See if any need to be deleted
	my $descFileSum = "$fileSum (" . humanBytes($fileSum) . ")";
	my $descLibSize = "$maxSize (" . humanBytes($maxSize) . ")";
	if ($fileSum <= $maxSize) {
		writeLog "  Nothing to delete, library size $descFileSum <= max size $descLibSize.";
		return;
	}

	# How much space we need to free up
	my $delSize = $fileSum - $maxSize;
	writeLog "  Library size $descFileSum > max size $descLibSize.  Some files will be deleted.";

	for my $fileName (sortByPref($files)) {
		# Keep trying to delete files until we've freed up enough space
		if ($delSize > 0) {
			my $action = 'keep';
			$action = 'delete' if !$conf->{watched_only} || $files->{$fileName}{views};
			my $deleted = actionFile($action, $files, $fileName);
			if ($action eq 'delete') {
				if ($deleted) {
					$delCount++;
					$delSize -= $files->{$fileName}{size};
				} elsif (!$conf->{continue_on_error}) {
					writeLog "  Not attempting to delete any more files in this library, set continue_on_error=True to override this.";
					last;
				}
			}
		} else {
			actionFile('keep', $files, $fileName);
		}
	}
	return $delCount;
}

# Delete files until the library has no more than the given number of files in it
sub deleteByCount {
	my ($files, $conf) = @_;
	my $maxCount = $conf->{count};

	# First see if there's anything to delete
	my $nFiles = keys %$files;
	# How many files we want to delete
	my $toDelete = $nFiles - $maxCount;
	# How many files we have deleted
	my $delCount = 0;
	if ($toDelete <= 0) {
		writeLog "  Nothing to delete, library has $nFiles file" . ($nFiles == 1 ? '' : 's') . " (<= $maxCount).";
		return;
	}
	writeLog "  Library has $nFiles (> $maxCount), want to delete $toDelete.";

	# Delete files from the beginning of this list first
	my @files = sortByPref($files);
	for my $fileName (@files) {
		# Keep trying to delete files until we're down to $maxCount
		if ($delCount < $toDelete) {
			my $action = 'keep';
			$action = 'delete' if !$conf->{watched_only} || $files->{$fileName}{views};
			my $deleted = actionFile($action, $files, $fileName);
			if ($action eq 'delete') {
				if ($deleted) {
					$delCount++;
				} elsif (!$conf->{continue_on_error}) {
					writeLog "  Not attempting to delete any more files in this library, set continue_on_error=True to override this.";
					last;
				}
			}
		} else {
			actionFile('keep', $files, $fileName);
		}
	}
	return $delCount;
}

# Take an action on a file. When called with 'keep', it can log the same format messages.
sub actionFile {
	my ($action, $files, $fileName) = @_;
	my $deleted = 0;
	if ($action eq 'delete') {
		if ($TEST) {
			writeLog "  TEST: would delete file $fileName", 1;
			$deleted = 1;
		} else {
			writeLog "  Deleting file $fileName", 1;
			if (unlink $fileName) {
				$deleted = 1;
			} else {
				writeLog "  ERROR: failed to delete file '$fileName': $!";
			}
		}
	} elsif ($action eq 'keep') {
		writeLog "  Keeping file $fileName", 2;
	}

	# Optionally show some basic file stats
	my ($rating, $age, $size, $views) = @{$files->{$fileName}}{qw/userRating age size views/};
	writeLog "    rating = " . ($rating // 0) . ", age = $age, size = $size (" . (humanBytes($size)) . "), views = $views", 2;
	return $deleted;
}

# Return a list of filenames sorted in the order in which they should be deleted.
sub sortByPref {
	my ($files) = @_;
	return sort {
		# First sort by userRating, low to high
		($files->{$a}{userRating} // 0) <=>
		($files->{$b}{userRating} // 0) ||
		# Then sort by age, oldest to newest
		$files->{$b}{age} <=> $files->{$a}{age}
	} keys %$files;
}

# Contact PMS and ask for a list of all libraries.  Have to do this so we know what key to use
# when listing files in a library named in the config.
sub getLibraries {
	my $libraries;
	for my $dirNode (getNodes('library/sections/', 'MediaContainer/Directory')) {
		my $attrs = attrs_to_hash($dirNode);
		$libraries->{$attrs->{title}} = $attrs;
	}
	return $libraries;
}

# Given a DOM element, return a list of all children
sub childElements {
	my ($parent) = @_;
	my @children;
	for my $node ($parent->childNodes) {
		next unless ref $node eq 'XML::LibXML::Element';
		push @children, $node;
	}
	return @children;
}

# Given a URL and an XPath, return a list of all DOM nodes matching the path.
sub getNodes {
	my ($url, $path) = @_;
	my @nodes;

	# Use an async http get
	my $wait = AE::cv;
	http_get "$BASE/$url", sub {
		my ($body, $headers) = @_;
		if ($headers->{Status} !~ /^2/) {
			# Want to exit this function, but not just yet
			AE::postpone {$wait->send};
			# Show a stack trace
			confess "ERROR: status $headers->{Status} trying to download: $BASE/$url";
		}
		my $doc = XML::LibXML->load_xml(string => $body);
		my $xpc = XML::LibXML::XPathContext->new($doc);
		@nodes = $xpc->findnodes($path);
		$wait->send;
	};

	# Wait until the document is downloaded and parsed.
	$wait->recv;
	return @nodes;
}

# Given a DOM node, return a hashref of attributes
sub attrs_to_hash {
	my ($node) = @_;
	my $attrHash = {};
	for my $attr ($node->attributes) {
		$attrHash->{$attr->nodeName} = $attr->value;
	}
	return $attrHash;
}

sub readConfig {
	my ($fileName) = @_;
	local $_;

	# Set internal defaults that may be overridden by config file
	my $conf = {
		main => {
			plexhost => 'localhost',
			plexport => '32400',
		},
	};

	my $section = 'main';
	if (open my $CONF, '<', $fileName) {
		while (<$CONF>) {
			# Skip blank lines and comments
			next if /^\s*(?:#|$)/;

			if (/^\s*\[\s*(.+?)\s*\]/) {
				# New section
				$section = $1;

			} elsif (/^\s*(.+?)\s*=\s*(.+?)\s*$/) {
				# Key = Value within a section
				my ($name, $value) = ($1, $2);

				# Some config items get coerced into boolean values
				$value = $BOOL_MAP->{lc $value} ? 1 : 0 if $BOOL_CONF->{$value};

				if ($section eq 'main') {
					$conf->{main}{$name} = $value;
				} else {
					$value = standardizeUnits($name, $value);
					$conf->{libraries}{$section}{$name} = $value;
				}
			} else {
				print "Skipping unparseable line: $_";
			}
		}
		close $CONF;
	} else {
		die "ERROR: failed to open config file '$fileName' for reading: $!\n";
	}

	return $conf;
}

# Convert numbers in various units into their base unit
sub standardizeUnits {
	my ($name, $value) = @_;
	if ($name eq 'age') {
		# Convert units into seconds
		$value =~ /([0-9.]+)\s*(\S*)/;
		my ($num, $units) = ($1, $2);
		$value = $num * $AGEUNITS->{lc($units || 'seconds')};
	} elsif ($name eq 'size') {
		# Convert units into bytes
		$value =~ /(\d+)\s*([$SI]?)$/i || die "ERROR: invalid units (must be one of '$SI') in size: $_";
		$value = $1 * 1024 ** index uc $SI, uc $2;
	}
	return $value;
}

# Convert a potentially large size into a more readable value with an SI suffix
sub humanBytes {
	my ($num) = @_;
	my $unit = 0;
	my $string = '';
	my @si = split //, $SI;
	while ($num >= 1000) {
		$num /= 1024;
		$unit++;
	}
	$unit = $si[$unit];
	if ($num >= 10 || $num == int $num) {
		$string = sprintf("%d$unit", $num);
	} elsif ($num >= 1) {
		$string = sprintf("%3.1f$unit", $num);
	} else {
		$string = sprintf("%3.2f$unit", $num);
	}
	return $string;
}

# Write a timestamped log message
sub writeLog($;$) {
	my ($text, $level) = @_;
	$level //= 0;
	# Some messages only get printed in verbose mode
	return unless $VERBOSE >= $level;

	print strftime("%Y/%m/%d %H:%M:%S: ", localtime) . $text;
	print "\n" unless "\n" eq substr $text, -1, 1;
}
