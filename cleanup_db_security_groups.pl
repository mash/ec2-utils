#!/usr/bin/env perl
use strict;
use warnings;
use Config::Pit;
use Net::Amazon::EC2;
use Array::Diff;
use Data::Dumper;
use Getopt::Long;

my ($pit, $region, $from_name, $to_name, $port);
$region = 'us-west-1';
$port   = 3306;
GetOptions ( "pit|p=s"    => \$pit,
             "region|r:s" => \$region,
             "from=s"     => \$from_name,
             "to=s"       => \$to_name,
             "port=i"     => \$port,
         )
    or die usage();
($pit && $from_name && $to_name)
    or die usage();

my $config = pit_get( $pit, require => {
    AWSAccessKeyId  => 'access key id',
    SecretAccessKey => 'secret access key',
});

my $ec2 = Net::Amazon::EC2->new(
    AWSAccessKeyId  => $config->{AWSAccessKeyId},
    SecretAccessKey => $config->{SecretAccessKey},
    region          => $region,
);

my $security_groups = $ec2->describe_security_groups( GroupName => $to_name );
my @permissions     = @{ $security_groups->[0]->ip_permissions };

# port22はsshのパーミッションだからそれ以外が現状接続を許可されているIP
my @current_permissions   = grep { ($_->from_port eq $port) && ($_->to_port eq $port) } @permissions;
my @current_permitted_ips = map { my $ip = $_->ip_ranges->[0]->cidr_ip; $ip =~ s!/32!!; $ip; } @current_permissions;

# $from_nameのセキュリティグループに入ってるサーバからは接続できるようにしたいから、それらのIPを確認
my $instances          = $ec2->describe_instances;
my @running_instances  = grep { $_->instances_set->[0]->instance_state->name eq 'running' } @{ $instances };
my @from_instances     = grep { $_->group_set->[0]->group_id eq $from_name } @running_instances;
my @next_permitted_ips = map { $_->instances_set->[0]->private_ip_address; } @from_instances;

my $diff = Array::Diff->diff( \@current_permitted_ips, \@next_permitted_ips );

# IPを削除
for my $deleting_ip ( @{ $diff->deleted } ) {
    print "deleting: $deleting_ip\n";
    my $ret = $ec2->revoke_security_group_ingress(
        GroupName  => $to_name,
        IpProtocol => 'tcp',
        FromPort   => $port,
        ToPort     => $port,
        CidrIp     => "$deleting_ip/32",
    );
    print " ERROR: ".Dumper($ret)."\n" unless $ret == 1;
}

# IPを追加
for my $adding_ip ( @{ $diff->added } ) {
    print "adding: $adding_ip\n";
    my $ret = $ec2->authorize_security_group_ingress(
        GroupName  => $to_name,
        IpProtocol => 'tcp',
        FromPort   => $port,
        ToPort     => $port,
        CidrIp     => "$adding_ip/32",
    );
    print " ERROR: ".Dumper($ret)."\n" unless $ret == 1;
}

if ( ( scalar @{ $diff->deleted } == 0 ) && ( scalar @{ $diff->added } == 0 ) ) {
    print "none deleted nor added\n";
}

sub usage {
    "usage: $0 -p <pit_key> --from <from_security_group_name:String> --to <to_security_group_name:String>";
}
