#!/usr/bin/env perl
use strict;
use warnings;
use Config::Pit;
use Net::Amazon::EC2;
use Getopt::Long;
use Config::Any;
use List::MoreUtils qw/firstval/;
use Array::Diff;
use Data::Dumper;

# ensure security group rules are the same as written in conf file
# perl script/ec2/setup_security_groups.pl -p art -r ap-northeast-1 conf/ec2_security_groups.pl

my ($pit, $region);
$region = 'us-west-1';
GetOptions ( "pit|p=s"    => \$pit,
             "region|r:s" => \$region,
         );
my $config_file = shift @ARGV
    or die usage();

($pit && $region && (-e $config_file))
    or die usage();

my $aws_config = pit_get( $pit, require => {
    AWSAccessKeyId  => 'access key id',
    SecretAccessKey => 'secret access key',
});

my $ec2 = Net::Amazon::EC2->new(
    AWSAccessKeyId  => $aws_config->{AWSAccessKeyId},
    SecretAccessKey => $aws_config->{SecretAccessKey},
    region          => $region,
);

my $config = Config::Any->load_files({ files => [ $config_file ], use_ext => 1, flatten_to_hash => 1 });
$config    = $config->{ $config_file };

for my $security_group_name (keys %$config) {
    my $permission_settings = $config->{ $security_group_name };

    my $security_groups = $ec2->describe_security_groups( GroupName => $security_group_name );
    my @real_permissions     = @{ $security_groups->[0]->ip_permissions };

    for my $permission_settings_entry (@$permission_settings) {

        # warn Dumper($permission_settings_entry);

        my $ip_protocol = $permission_settings_entry->{ ip_protocol };
        my $to_port     = $permission_settings_entry->{ to_port };

        print "\n";
        print "assure $ip_protocol from ".
            ($permission_settings_entry->{ from_cidrs } ?
                 join(', ', @{ $permission_settings_entry->{ from_cidrs } }) :
                 "servers in $permission_settings_entry->{ from_servers_in_security_group }").
            " to $to_port\n";

        # is equal if all: qw/ip_protocol to_port ip_ranges/ are the same

        # currently applied permission
        my $real_permission =
            firstval { ($_->ip_protocol eq $ip_protocol) && ($_->to_port == $to_port) } @real_permissions;

        if ( ! $real_permission ) {
            # exists in local settings, but not in remote
            # -> add it
            my $from_cidrs = $permission_settings_entry->{ from_cidrs };
            if ( ! $from_cidrs ) {
                my $from_name = $permission_settings_entry->{ from_servers_in_security_group };
                $from_cidrs = cidrs_for_servers_in_security_group( $ec2, $from_name );
            }
            for my $from_cidr (@$from_cidrs) {

                print "really add: $ip_protocol from $from_cidr to $to_port ? Ctrl+C to abort\n";
                getc(STDIN);

                my $ret = $ec2->authorize_security_group_ingress(
                    GroupName  => $security_group_name,
                    IpProtocol => $ip_protocol,
                    FromPort   => $to_port,
                    ToPort     => $to_port,
                    CidrIp     => $from_cidr,
                );
            }
        }
        else {
            # exists in local settings, and also in remote
            # update if details are different
            my $settings_cidr = $permission_settings_entry->{ from_cidrs };
            if ( ! $settings_cidr ) {
                my $from_name = $permission_settings_entry->{ from_servers_in_security_group };
                $settings_cidr = cidrs_for_servers_in_security_group( $ec2, $from_name );
            }
            my $current_ip_ranges = [ sort map { $_->cidr_ip } @{ $real_permission->ip_ranges } ];
            print "current: @$current_ip_ranges\n";
            print "set:     @$settings_cidr\n";

            my $diff = Array::Diff->diff( $current_ip_ranges, $settings_cidr );

            # IPを削除
            for my $deleting_cidr ( @{ $diff->deleted } ) {

                print "really delete: $ip_protocol from $deleting_cidr to $to_port ? Ctrl+C to abort\n";
                getc(STDIN);

                my $ret = $ec2->revoke_security_group_ingress(
                    GroupName  => $security_group_name,
                    IpProtocol => $ip_protocol,
                    FromPort   => $real_permission->from_port,
                    ToPort     => $to_port,
                    CidrIp     => "$deleting_cidr",
                );
                print " ERROR: ".Dumper($ret)."\n" unless $ret == 1;
            }

            # IPを追加
            for my $adding_cidr ( @{ $diff->added } ) {

                print "really add: $ip_protocol from $adding_cidr to $to_port ? Ctrl+C to abort\n";
                getc(STDIN);

                my $ret = $ec2->authorize_security_group_ingress(
                    GroupName  => $security_group_name,
                    IpProtocol => $ip_protocol,
                    FromPort   => $real_permission->from_port,
                    ToPort     => $to_port,
                    CidrIp     => "$adding_cidr",
                );
                print " ERROR: ".Dumper($ret)."\n" unless $ret == 1;
            }
        }
    }
}

sub cidrs_for_servers_in_security_group {
    my ($ec2, $security_group_name) = @_;

    my $instances          = $ec2->describe_instances;
    my @running_instances  = grep { $_->instances_set->[0]->instance_state->name eq 'running' } @{ $instances };
    my @from_instances     = grep {
        $_->group_set->[0] &&
            (($_->group_set->[0]->group_name eq $security_group_name) ||
             ($_->group_set->[0]->group_id   eq $security_group_name))
    } @running_instances;
    my @next_permitted_ips = map { $_->instances_set->[0]->private_ip_address; } @from_instances;

    return [ sort map { "${_}/32" } @next_permitted_ips ];}


sub usage {
    "usage: $0 -p <pit_key> [-r <region>] path/to/conf.pl";
}

__END__

# sample conf.pl
use strict;
use warnings;

return {
    'name-of-security-group' => [
        # identify entry by ip_protocol and to_port
        +{
            ip_protocol => 'tcp',
            to_port     => 22,
            from_cidrs  => [ '...snip.../32' ]
        },
        +{
            ip_protocol => 'tcp',
            to_port     => 80,
            from_cidrs  => [ '0.0.0.0/0' ]
        },
        +{
            ip_protocol => 'tcp',
            to_port     => 443,
            from_cidrs  => [ '0.0.0.0/0' ]
        },
        +{
            ip_protocol => 'icmp',
            to_port     => -1,
            from_cidrs  => [ '0.0.0.0/0' ]
        },
        +{
            ip_protocol                    => 'tcp',
            to_port                        => 24224, # fluentd
            from_cidrs                     => undef,
            from_servers_in_security_group => 'name-of-security-group',
        },
    ],
};
