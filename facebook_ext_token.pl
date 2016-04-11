#!/usr/bin/env perl
use 5.012;
use warnings;

use YAML::Tiny;
use LWP::Simple;
use JSON qw/from_json/;

my $configuration_file = '/srv/infoscreen.coq.dk/facebook.yaml';

my $yaml = YAML::Tiny->read($configuration_file);
my $config = $yaml->[0];

my $url = 'https://graph.facebook.com/v2.3/oauth/access_token?'.
          'grant_type=fb_exchange_token&'.
          'client_id=' . $config->{app_id} . '&' .
          'client_secret=' . $config->{app_secret} . '&' .
          'fb_exchange_token=' . $ARGV[0];

my $response = get($url);
print "$response\n";
$response = from_json($response);

my ($access_token) = $response->{access_token};
$config->{access_token} = $access_token;

print $ARGV[0] . "\n";
print $access_token . "\n";

$yaml->write($configuration_file);
print "Hvis du ikke fik fejl er token'en opdateret nu.\n";

