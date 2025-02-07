#!/usr/bin/perl

use strict;
use warnings;
use Test::More tests => 22;

use POE;
use POE::Component::Client::TCP;
use POE::Component::Server::TCP;
use POE::Component::SSLify qw/Client_SSLify Server_SSLify SSLify_Options SSLify_GetCipher SSLify_ContextCreate/;
use Net::SSLeay qw/ERROR_WANT_READ ERROR_WANT_WRITE/;
use POSIX qw/F_GETFL F_SETFL O_NONBLOCK EAGAIN EWOULDBLOCK/;

my $port;

POE::Component::Server::TCP->new
(
	Alias			=> 'myserver',
	Address			=> '127.0.0.1',
	Port			=> 0,

	Started			=> sub
	{
		use Socket qw/sockaddr_in/;
		$port = (sockaddr_in($_[HEAP]->{listener}->getsockname))[0];
	},
	ClientConnected		=> sub
	{
		ok(1, 'SERVER: accepted');
	},
	ClientDisconnected	=> sub
	{
		ok(1, 'SERVER: client disconnected');	
		$_[KERNEL]->post(myserver => 'shutdown');
	},
	ClientPreConnect	=> sub
	{
		eval { SSLify_Options('mylib/example.key', 'mylib/example.crt', 'sslv3') };
		eval { SSLify_Options('../mylib/example.key', '../mylib/example.crt', 'sslv3') } if ($@);
		ok(!$@, "SERVER: SSLify_Options $@");

		my $socket = eval { Server_SSLify($_[ARG0]) };
		ok(!$@, "SERVER: Server_SSLify $@");
		ok(1, 'SERVER: SSLify_GetCipher: '. SSLify_GetCipher($socket));

		my $flags = fcntl($_[ARG0], F_GETFL, 0);
		ok($flags & O_NONBLOCK, 'SERVER: SSLified socket is non-blocking?');

		return ($socket);
	},
	ClientInput		=> sub
	{
		my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];

		## At this point, connection MUST be encrypted.
		my $cipher = SSLify_GetCipher($heap->{client}->get_output_handle);
		ok($cipher ne '(NONE)', "SERVER: SSLify_GetCipher: $cipher");

		if ($request eq 'ping')
		{
			ok(1, "SERVER: recv: $request");
			$heap->{client}->put("pong");
		}
		elsif ($request eq 'ping2')
		{
			ok(1, "SERVER: recv: $request");
			$heap->{client}->put("pong2");
		}
	},
);

POE::Component::Client::TCP->new
(
	Alias		=> 'myclient',
	RemoteAddress	=> '127.0.0.1',
	RemotePort	=> $port,
	Connected	=> sub
	{
		ok(1, 'CLIENT: connected');

		$_[HEAP]->{server}->put("ping");
	},
	PreConnect	=> sub
	{
		my $ctx = eval { SSLify_ContextCreate(undef, undef, 'sslv3') };
		ok(!$@, "CLIENT: SSLify_ContextCreate $@");
		my $socket = eval { Client_SSLify($_[ARG0], undef, undef, $ctx) };
		ok(!$@, "CLIENT: Client_SSLify $@");
		ok(1, 'CLIENT: SSLify_GetCipher: '. SSLify_GetCipher($socket));

		my $flags = fcntl($_[ARG0], F_GETFL, 0);
		ok($flags & O_NONBLOCK, 'CLIENT: SSLified socket is non-blocking?');

		return ($socket);
	},
	ServerInput	=> sub
	{
		my ($kernel, $heap, $line) = @_[KERNEL, HEAP, ARG0];

		## At this point, connection MUST be encrypted.
		my $cipher = SSLify_GetCipher($heap->{server}->get_output_handle);
		ok($cipher ne '(NONE)', "CLIENT: SSLify_GetCipher: $cipher");

		if ($line eq 'pong')
		{
			ok(1, "CLIENT: recv: $line");

			## Force SSL renegotiation
			my $ssl = tied(*{$heap->{server}->get_output_handle})->{ssl};
			my $reneg_num = Net::SSLeay::num_renegotiations($ssl);

			ok(1 == Net::SSLeay::renegotiate($ssl), 'CLIENT: SSL renegotiation');
			my $handshake = Net::SSLeay::do_handshake($ssl);
			my $err = Net::SSLeay::get_error($ssl, $handshake);

			## 1 == Successful handshake, ERROR_WANT_(READ|WRITE) == non-blocking.
			ok($handshake == 1 || $err == ERROR_WANT_READ || $err == ERROR_WANT_WRITE, 'CLIENT: SSL handshake');
			ok($reneg_num < Net::SSLeay::num_renegotiations($ssl), 'CLIENT: Increased number of negotiations');

			$heap->{server}->put('ping2');
		}

		elsif ($line eq 'pong2')
		{
			ok(1, "CLIENT: recv: $line");
			$kernel->yield('shutdown');
		}
	},
);

$poe_kernel->run();
exit 0;
