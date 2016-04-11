#!/usr/bin/env perl
use 5.012;
use warnings;

use Mojolicious::Lite;

use CHI;
use DateTime::Format::ISO8601;
use Facebook::Graph;
use YAML::Tiny;
use experimental qw(smartmatch autoderef);
use Try::Tiny;
use utf8::all;
use List::Util qw/shuffle/;
use List::MoreUtils qw/uniq/;


my $fb_config_file = '/srv/infoscreen.coq.dk/facebook.yaml';

my $yaml = YAML::Tiny->read($fb_config_file);
my $config = $yaml->[0];

my $cache = CHI->new( driver => 'Memory', global => 1 );

get '/fb/dikumemes' => sub {
    my $c = shift;

    my $res = $cache->compute("fb_dikumemes", "20 minutes", sub {
        my $fb;
        try {
            $fb = Facebook::Graph->new(
                app_id       => $config->{app_id},
                app_secret   => $config->{app_secret},
                access_token => $config->{access_token},
            );
        } catch {
            return { error => "Facebook creds er udløbet." };
#        print "Mine Facebook credentials er udløbet. :(\n";
#        print STDERR "En eller anden log ind som concieggs på fjæseren, gå ind på https://developers.facebook.com/tools/explorer/1552430738354823 og tryk 'Get Access Token' i toppen.\n";
#        print STDERR "Kør så følgende fra en commandline: $ext_token_script <token>";
            return;
        };

        my @group_feed = grep { $_->{link} =~ qr{facebook\.com/photo\.php} } @{ $fb->fetch('1676857065872315/feed')->{data} };
        my @res;
        for my $element (@group_feed) {
            my $elm = $fb->fetch($element->{object_id});
            $element->{imagedata} = $elm;
            push(@res, $element);
        }
        return { elements => \@res };
    });

    $c->res->headers->add('Access-Control-Allow-Origin' => '*');
    $c->render(json => $res);
};

sub get_banko_user {
	my $c = shift;

	my $user = $c->cookie('name');
	my $data = load_banko_data($user) // initialize_banko_data($user);

	$c->stash(
		user      => $user,
		user_data => $data,
	);

	return ($user, $data);
}

# Infoskærms-banko
my $active_number = -1;

get '/banko' => sub {
    my $c = shift;

	get_banko_user($c);

    return $c->render(template => 'banko');
};

get '/banko/boards' => sub {
	my $c = shift;

	my ($user, $data) = get_banko_user($c);
	return $c->render(status => 403) unless $user && $data;

	return $c->render( json => $data->{boards} );
};

get '/banko/mark' => sub {
	my $c = shift;

	my ($user, $data) = get_banko_user($c);
	return $c->render(status => 403) unless $user && $data;

	my $n = int( $c->param('board') );
	my $row = int( $c->param('row') );
	my $col = int( $c->param('col') );

	if ($n >= 0 && $n < scalar @{ $data->{boards} } &&
        $row >= 0 && $row < 3 &&
		$col >= 0 && $col < 9) {
		my $board = $data->{boards}->[$n];
		if ($board->{board}->[$row]->[$col] == $active_number) {
			unless (grep { $_->{c} == $col && $_->{r} == $row } @{ $board->{markers} }) {
				push( @{ $board->{markers} }, { c => $col, r => $row } );
			}
			save_banko_data($user, $data);
			return $c->render(json => Mojo::JSON->true);
		}
	}
	return $c->render(json => Mojo::JSON->false);
};

websocket '/banko/ws' => sub {
	my $c = shift;

	$active_number = int( rand(90) + 1 );
	$c->inactivity_timeout(10);
	$c->app->log->debug("Connected to websocket");

	$c->on( message => sub {
		my $c = shift;
		$c->app->log->debug("Number $active_number is active.");
		$c->send($active_number);
	} );

	$c->on( finish => sub {
		my ($c, $code, $reason) = @_;
		$active_number = -1;
		$c->app->log->debug("Disconnected from socket; number inactive.");
	} );
};

=head2 gen_board

Genererer en tilfældig bankoplade

=cut
sub gen_board {

	# Først laver vi et skema over hvor tallene skal være på bankopladen
	my @skema;
	for my $row (0..2) {
		push(@skema, [ sort { $a <=> $b } ((shuffle (0..8))[0..4]) ]);
	}

	# Så sikrer vi os, at der er mindst et tal i hver søjle.
	my @span = (0..8);
	my @all_nums = sort { $a <=> $b } (uniq (map { @$_ } @skema));
	return gen_board() unless @all_nums ~~ @span;

	# Så randomiserer vi rækkefølgen på tallene i hver søjle
	my @nums;
	for my $col (0..8) {
		my @pos = $col eq 0 ? (1..9) :
                  $col eq 8 ? (80..90) : (($col*10) .. ($col*10+9));
		push( @nums, [ shuffle @pos ] );
	}

	# Fyld pladen op!
	my @res = map { [] } (0..2);
	for my $col (0..8) {
		for my $row (0..2) {
			my $num = 0;
			if (@{ $skema[$row] } && $skema[$row]->[0] eq $col) {
				shift @{ $skema[$row] };
				$num = shift @{ $nums[$col] };
			}
			push (@{ $res[$row] }, $num);
		}

		my $swap = sub {
			my ($col, $a, $b) = @_;
			return unless ($a->[$col] != 0 && $b->[$col] != 0
                       && $a->[$col] > $b->[$col]);

			my $tmp = $a->[$col];
			$a->[$col] = $b->[$col];
			$b->[$col] = $tmp;
		};
		$swap->($col,$res[0],$res[2]);
		$swap->($col,$res[1],$res[2]);
		$swap->($col,$res[0],$res[1]);
	}

	return \@res;
}

my $banko_config_dir = '/srv/infoscreen.coq.dk/banko_data';

=head2 load_banko_data

Loads banko data for a given user

=cut
sub load_banko_data {
	my $user = shift;

	my $hex = unpack( 'H*', $user );
	my $config_file = "$banko_config_dir/$hex.yaml";

	return unless -f $config_file;
	my $yaml = YAML::Tiny->read($config_file);
	return $yaml->[0];
}

=head2 save_banko_data

Saves banko data for a given user

=cut
sub save_banko_data {
	my $user = shift;
	my $data = shift;

	my $hex = unpack( 'H*', $user );
	my $config_file = "$banko_config_dir/$hex.yaml";

	my $yaml = YAML::Tiny->new( $data );
	$yaml->write($config_file);
}

=head2 initialize_banko_data

Initializes the banko data for a given user

=cut
sub initialize_banko_data {
	my $user = shift;
	return unless $user;

	my $data = {
		name   => $user,
		boards => [ map { { board => gen_board(), markers => [] } } (0..2) ],
	};

	save_banko_data($user, $data);
	return $data;
}

app->config(hypnotoad => {
    pid => '/var/run/web/infoscreen.pid',
    listen => [ 'http://127.0.0.1:14500' ],
});

app->start;
