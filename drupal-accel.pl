#!/usr/bin/perl -w
use strict;

################################################################
# Script:  drupal-accel.pl
#
# Author:  Richard Connett
# Date:    2008-03-26
#
# Desc:    A url rewriter script for sift drupal sites
#
# Version: 1.0
################################################################

# Don't cache the output
$|=1;

################################
# A few hard coded config values

my $debug = 0;			# Debug level
#my $config_dir = '/usr/local/squid-2.6/etc/drupal-accel/drupal-holding-cfgs';
#my $config_dir = '/usr/local/squid/etc/drupal-accel/drupal-accel-cfgs';
my $config_dir = '/etc/squid/drupal-accel/drupal-accel-cfgs';
my %allowed_types = (site => 1, 301 => 1, 302 => 1, static => 1);
my %pages = (NOTKNOWN => '302:http://www.sift.com/accel-error.html');
#my %pages = (NOTKNOWN => '302:http://172.20.0.50/general_holding/index.html');

################################
# Now a few global vars

my @rules;

################################

warn " --- drupal-accel.pl $$ starting up ---";

################################
# Firstly read in the config files
read_rewrite_configs();

warn " --- drupal-accel.pl $$ startup complete ---";

################################
# Now enter a loop reading STDIN from squid
while (my $line = <STDIN>) {
    rewrite($line);
}

warn " --- drupal-accel.pl $$ closing normally ---";
exit 0;

# Read in the config files
sub read_rewrite_configs {

    # Find all the config files in the config dir
    my @files;
    opendir(DIR,$config_dir) or die "Failed to open config dir $config_dir $!";
    while (my $fname = readdir(DIR)) {
	next unless $fname =~ /\.cfg$/;	# We're only interested in *.cfg files
        push @files, $fname;
    }
    close(DIR);

    # Loop over each config in alphabetical order
    foreach my $fname (sort @files) {
	my $file = $config_dir.'/'.$fname;

	# Open the file
	open(FH,"<$file") or die "Failed to open config file $file $!";
        warn "Processing: $file";
	# Read the file
	while (my $line = <FH>) {
	    chomp $line;

	    # Skip the line if it's blank or starts with a hash
	    next if ($line =~ /^\s*$/ or $line =~ /^\s*#/);

	    # Parse the line
	    my ($url,$target,$type) = split(/\s+/,$line,3);

            # Make sure we've got a value for each field
            unless (defined $url and defined $target and defined $type) {
                warn "ERROR: $file - invalid line [$line] - SKIPPING";
                next;
            }

	    # Check the type is ok
	    unless (exists $allowed_types{$type} and $allowed_types{$type}) {
		warn "ERROR: $file - Type $type not recognised - SKIPPING";
                next;
	    }

            # What sort of rulematch is our url?
            if ($url =~ /^PERLREGEX:(.+)/) {
                # It's a nice perl regex already, just use it
                $url = $1;
            } else {
                # It's just using * as a wildcard, quote everything and change * to .*
                $url = quotemeta($url);
                $url =~ s/\\\*/\.\*/;
            }


	    push @rules, {url => $url,
			  target => $target,
			  type => $type};
	}

        close(FH);
    }
}

# Rewrite the given request
sub rewrite {
    my ($line) = @_;
    warn "Processing line: [$line]" if $debug>2;
    chomp $line;

    # Parse the line
    my ($url,$client,$ident,$method,$urlgroup) = $line =~ m!^(.*?)\s+(.*?)\s+(.*?)\s+(.*?)\s+(.*)!;
    unless (defined $url and defined $client and defined $ident and defined $method) {
	warn  "Squid delivered us a bad line to rewrite [$line]";
	print $pages{NOTKNOWN}."\n";
	return;
    }

    if ($debug > 2) {
	warn "Redirector process $$";
	warn "URL: $url\nCLIENT: $client\nIDENT: $ident\nMETHOD: $method";
    }

    my ($proto,$fqdn,$path) = ($url =~ m!^(.*?)://(.*?)/(.*)$!);
    unless (defined $proto and defined $fqdn and defined $path) {
	warn "Unable to parse url [$url]";
	print $pages{NOTKNOWN}."\n";
	return;
    }
    my $fullpath = $fqdn.'/'.$path;
    if ($debug > 2) {
	warn "PROTO: $proto\nFQDN: $fqdn\nPATH: $path";
    }

    if ($proto eq "cache_object") { ## Squid cache manager
	print "\n";		## pass through unchanged
	return;
    }

    # Loop over our rules looking for a match
    foreach my $rule (@rules) {
	my $rulematch = '^'.$rule->{url};
	if ($fullpath =~ /$rulematch/) {
	    warn " ===> Orig URL [$fullpath]\n ----- matches [$rulematch]" if $debug>1;
            # We've got a match, do what is required
            my $newurl = '';
	    if ($rule->{type} =~ /^30[12]$/) {
		# Force a client redirect
		$newurl = $rule->{type}.':'.$rule->{target}.'/'.$path;
	    } elsif ($rule->{type} eq 'site') {
		# We want to process this request, forward to appropriate place
                # Include the port if one has been included in the orig request
                my ($port) = $fqdn =~ m!(\:\d+)!;
                $port ||= '';
		$newurl = $proto.'://'.$rule->{target}.$port.'/'.$path;
	    } elsif ($rule->{type} eq 'static') {
		# Do a holding page
		$newurl = $rule->{target};
	    } else {
                warn "ERROR - Unknown rule type [".$rule->{type}."]";
                last;
            }

            warn " <=== Resulting rewritten url [$newurl]" if $debug>1;
            print $newurl."\n";

	    # Our work is done
	    return;
	}
    }

    # Oh dear, we've not matched anything, better return an error page
    warn "ERROR - No matches found for [$fullpath]";
    print $pages{NOTKNOWN}."\n";
}

=pod

=head1 NAME

drupal-accel.pl

=head1 AUTHOR

Richard Connett

=head1 VERSION

1.0

=head1 SYNOPSIS

This script is designed to be used by squid to rewrite urls for the drupal sites that sift host.  However there's no reason why it can't do non-drupal sites.

The script will look for config files with the 'cfg' extension in the $config_dir directory and use the contents when determining the rewrites.  If an applicable rewrite rules can't be found for a given url then the error page defined by $pages{NOTKNOWN} will be returned.

Each config file should be in the following format:

  # URL                   TARGET                        TYPE
  www.iom3.com/phplist*   phplist.farm.sift.co.uk       site
  www.iom3.org*           paproxy.farm.sift.co.uk       site
  iom3.org*               http://www.iom3.org           301
  uk.iom3.org*            http://www.iom3.org           302
  fake.iom3.org*          http://www.iom3.org/holdingpage.html   static

=over 4

=item URL

should be a string to test a match against the incoming url.  It can either be a plain string with a '*' as a wildcard match or you can use a full perl regex functionality.  To use perl regex prefile the url with PERLREGEX: and make sure you quote it appropriately with backslashes (especially those full stops in the urls) i.e.

   PERLREGEX:www\.iom3\.com\/\w+$

=item TYPE

currently the following types are handled:  site, 301, 302 and static

=over 8

=item site

The request will be forwarded to TARGET using the incoming protocol and incoming path

=item 301

A 301 redirect request to the TARGET will be sent back to the client.  TARGET should include the appropriate protocol.

=item 302

A 302 redirect request to the TARGET will be sent back to the client.  TARGET should include the appropriate protocol.

=item static

The request will be forwarded to the static page, use for holding pages etc.  TARGET should include the appropriate protocol.

=back

=item TARGET

should be the target to use dependant on the TYPE

=back

Blank lines and lines starting with a hash are ignored.  The fields should be separated by spaces or tabs.

=head1 IMPORTANT - RULE ORDER

The order of the rules is important, in the above example it's important that the rule for phplist comes before the main site rewrite.  This is because it's the first rule which matches the request that gets used.  As all the rules from all the config files are put in a single list of rules the order that the files are processed is also important, they will be done in alphabetical order.

=head1 NOTES

The debug level can be set by adjusting the $debug var at the top of the script.  Setting it to 0 turns off al debug.

The config directory can be ammended by changing the $config_dir var at the top of the script, it can either be relative or absolute.

=cut

